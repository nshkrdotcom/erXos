# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'qemu'

module Erx
  module NetDevice
    # The name server the harness plays on the guest's link once the ARP and ICMP exchange
    # is done, so the `host` command has a server whose answers the test fixes and the run
    # stays offline: slirp's own name server, 10.0.2.3, forwards to the host's resolver,
    # whose answers no test controls. It answers, from HOST_MAC and HOST_IP, ARP requests
    # for HOST_IP and DNS queries to HOST_IP port 53 from the records in RECORDS:
    # NOERROR with the matching records for a name RECORDS knows, NXDOMAIN for any other.
    # It is the NTP server of ntpd and of the `ntpdate` command too: an SNTP client request
    # to HOST_IP port 123 gets a stratum-1 reply that says the time is NTP_AHEAD seconds
    # past the host's clock, until the run fixes it at NTP_TIME (fix_ntp_time). The first
    # answer is within the clock service's 1000 s panic threshold of a guest whose clock the
    # real-time clock set at boot, so ntpd's first sample is held and its second steps
    # (docs/design-time.md, "Steps"); the second makes ntpdate's step one to a time the test
    # fixes (docs/design-time.md, "Setting the clock from a server once").
    #
    # Every frame comes from the guest, the code under test, so each is parsed with bounds
    # checks and one that is not a well-formed request of these two kinds is skipped. The
    # answers run on a thread of their own, from start until stop, while the boot's
    # checkpoints read the serial line.
    class NameServer
      DNS_PORT = 53
      NTP_PORT = 123
      # Seconds from 1900, NTP's epoch, to 1970.
      NTP_EPOCH = 2_208_988_800
      # The time NTP replies give once fixed, 2030-01-01 00:00:00 UTC, as NTP seconds.
      NTP_TIME = Time.utc(2030, 1, 1).to_i + NTP_EPOCH
      # How far past the host's clock NTP replies are until then, in seconds: beyond the
      # 128 ms at which a sample is held and within the 1000 s at which it is refused.
      NTP_AHEAD = 300
      PROTOCOL_UDP = 17
      TYPE_A = 1
      TYPE_PTR = 12
      TYPE_AAAA = 28
      CLASS_IN = 1
      TTL = 60
      RCODE_NXDOMAIN = 3
      POLL_SECONDS = 0.2
      # The name the records answer for and its addresses: the host command's checks.
      NAME = "www.#{QemuPlan::NIC_DOMAIN}"
      ADDRESS = [192, 0, 2, 10].freeze
      ADDRESS6 = [0x2001, 0xdb8, 0, 0, 0, 0, 0, 0x10].freeze
      POINTER = "#{ADDRESS.reverse.join('.')}.in-addr.arpa"

      def self.labels(name) = name.split('.').map { |label| [label.bytesize].pack('C') + label.b }.join + "\0".b

      RECORDS = {
        [NAME, TYPE_A] => ADDRESS.pack('C*'),
        [NAME, TYPE_AAAA] => ADDRESS6.pack('n*'),
        [POINTER, TYPE_PTR] => labels(NAME)
      }.freeze
      NAMES = RECORDS.keys.map(&:first).uniq.freeze

      def initialize(link)
        @link = link
        @stopped = false
        @thread = nil
        @ntp_fixed_at = nil
      end

      # From now on NTP replies say NTP_TIME plus the seconds since this call, so a clock
      # set from them stays set. The answer thread only reads the time, and one assignment
      # needs no lock.
      def fix_ntp_time
        @ntp_fixed_at = Time.now.to_i
      end

      # The thread's value is the error it met, or nil, so stopping it never raises and a
      # run's own failure is never replaced by the server's.
      def start
        @thread = Thread.new do
          @link.await(POLL_SECONDS) { |frame| answer(frame) } until @stopped
          nil
        rescue StandardError => e
          e
        end
        self
      end

      # Stops the answers and returns the error the thread met, or nil.
      def stop
        @stopped = true
        @thread&.value
      end

      private

      # Sends the answer to frame, if it is one this server answers, and returns nil so the
      # link's await goes on reading.
      def answer(frame)
        reply = arp_reply(frame) || udp_reply(frame)
        @link.send(reply) if reply
        nil
      end

      def arp_reply(frame)
        return nil unless frame.bytesize >= 42 && frame.unpack1('@12n') == ETHERTYPE_ARP

        htype, ptype, hlen, plen, op = frame.unpack('@14nnCCn')
        sender, sender_ip, _target, target_ip = frame.unpack('@22a6a4a6a4')
        return nil unless [htype, ptype, hlen, plen, op] == [1, ETHERTYPE_IP, 6, 4, 1] && target_ip == NetDevice.bytes(HOST_IP)

        NetDevice.ethernet(sender.bytes, ETHERTYPE_ARP,
                           [1, ETHERTYPE_IP, 6, 4, 2].pack('nnCCn') + NetDevice.bytes(HOST_MAC) + NetDevice.bytes(HOST_IP) +
                           sender + sender_ip)
      end

      def udp_reply(frame)
        datagram = udp_to_server(frame)
        return nil unless datagram

        response = case datagram.fetch(:to_port)
                   when DNS_PORT then dns_response(datagram.fetch(:payload))
                   when NTP_PORT then ntp_response(datagram.fetch(:payload))
                   end
        response && udp_frame(datagram, response)
      end

      # The source, destination port and payload of a UDP datagram to HOST_IP, or nil.
      def udp_to_server(frame)
        return nil unless frame.bytesize >= 34 && frame.unpack1('@12n') == ETHERTYPE_IP

        version_ihl, total, protocol, source, destination = frame.unpack('@14C@16n@23C@26a4a4')
        header = (version_ihl & 0x0f) * 4
        return nil unless version_ihl >> 4 == 4 && header >= 20 && protocol == PROTOCOL_UDP && total >= header + 8 &&
                          frame.bytesize >= 14 + total && destination == NetDevice.bytes(HOST_IP)

        udp = frame.byteslice(14 + header, total - header)
        source_port, destination_port, length = udp.unpack('nnn')
        return nil unless length >= 8 && length <= udp.bytesize

        { mac: frame.byteslice(6, 6), ip: source, port: source_port, to_port: destination_port,
          payload: udp.byteslice(8, length - 8) }
      end

      # The response to a standard query of one question, or nil for anything else.
      def dns_response(query)
        return nil unless query.bytesize >= 12

        id, flags, questions = query.unpack('nnn')
        return nil unless questions == 1 && (flags & 0xf800).zero?

        name, finish = question_name(query, 12)
        return nil unless name && query.bytesize >= finish + 4

        type, klass = query.unpack("@#{finish}nn")
        return nil unless klass == CLASS_IN

        answers = RECORDS.key?([name, type]) ? [RECORDS.fetch([name, type])] : []
        rcode = NAMES.include?(name) ? 0 : RCODE_NXDOMAIN
        header = [id, 0x8400 | (flags & 0x0100) | rcode, 1, answers.size, 0, 0].pack('n6')
        header + query.byteslice(12, finish + 4 - 12) +
          answers.map { |data| [0xc00c, type, CLASS_IN, TTL, data.bytesize].pack('nnnNn') + data }.join
      end

      # The reply to an SNTPv4 client request (RFC 4330 section 5): version 4, mode 4,
      # stratum 1, the request's transmit timestamp as its originate, and the replies' time
      # (ntp_seconds) as its reference, receive and transmit times; nil for anything that is
      # not such a request.
      def ntp_response(request)
        return nil unless request.bytesize >= 48 && request.getbyte(0) & 0x3f == (4 << 3) | 3

        stamp = [ntp_seconds, 0].pack('NN')
        [(4 << 3) | 4, 1, 6, -20].pack('CCCc') + [0, 0].pack('NN') + 'GPS'.b + "\0".b +
          stamp + request.byteslice(40, 8) + stamp + stamp
      end

      # The NTP seconds the replies say: NTP_AHEAD past the host's clock until the run fixes
      # them, then NTP_TIME plus the seconds since.
      def ntp_seconds
        now = Time.now.to_i
        @ntp_fixed_at ? NTP_TIME + now - @ntp_fixed_at : now + NTP_AHEAD + NTP_EPOCH
      end

      # The question's name, lowercased, and the offset after it; nil for a compressed or
      # malformed name.
      def question_name(query, offset)
        labels = []
        loop do
          return nil if offset >= query.bytesize

          length = query.getbyte(offset)
          return [labels.join('.').downcase, offset + 1] if length.zero?
          return nil if length > 63 || offset + 1 + length > query.bytesize

          labels << query.byteslice(offset + 1, length)
          offset += 1 + length
        end
      end

      def udp_frame(datagram, payload)
        length = 8 + payload.bytesize
        pseudo = NetDevice.bytes(HOST_IP) + datagram.fetch(:ip) + [0, PROTOCOL_UDP, length].pack('CCn')
        udp = [datagram.fetch(:to_port), datagram.fetch(:port), length, 0].pack('nnnn') + payload
        udp = NetDevice.with_checksum(pseudo + udp, at: pseudo.bytesize + 6).byteslice(pseudo.bytesize..)
        # A sum of zero goes as all ones, since zero means no checksum (RFC 768).
        udp[6, 2] = "\xff\xff".b if udp.unpack1('@6n').zero?
        header = [0x45, 0, 20 + length, 0, 0, 64, PROTOCOL_UDP, 0].pack('CCnnnCCn') + NetDevice.bytes(HOST_IP) +
                 datagram.fetch(:ip)
        NetDevice.ethernet(datagram.fetch(:mac).bytes, ETHERTYPE_IP, NetDevice.with_checksum(header, at: 10) + udp)
      end
    end
  end
end
