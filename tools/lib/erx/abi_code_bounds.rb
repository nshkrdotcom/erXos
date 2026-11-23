# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_inspection_bounds'

module Erx
  module ABI
    # What abi/services/code.txt's limits let the code interface's terms be
    # (docs/design-live.md, "The code server", Floors), computed from
    # code_modules_max and code_piece_max alone, as upper bounds:
    #
    # * request_max, the longest request a facet of the interface carries, as
    #   erx_cmd_load and the facet measure it: erlang:external_size/1 of the
    #   gen_server call's envelope around a load of code_modules_max modules
    #   into a named domain, a reset or a put of one piece;
    # * load_floors, answer_floors and facet_floors, for each of the three
    #   limits the funnel applies to a frame (max_frame in bytes,
    #   max_message_heap in words, funnel_depth), the largest of any message
    #   the code protocol carries into a domain, out of it into the system
    #   domain, and between a code facet's grantee and its server, each rounded
    #   up to a power of two.
    #
    # Every name is counted at 255 bytes, every hash at 32, every size and
    # offset at the largest u64, and every pid and reference at the largest
    # node name, so the bounds hold whatever a domain's node is called.
    module CodeBounds
      NAME_MAX = InspectionBounds::MAX_ATOM
      HASH_BYTES = 32
      U64_MAX = (1 << 64) - 1
      # ERTS's largest small integer on a 64-bit build (liberx/erx_etf.c,
      # SMALL_MAX).
      SMALL_MAX = (1 << 59) - 1
      # A term's encoded bytes, its words on the receiver's heap as the funnel
      # counts them (liberx/erx_etf.c, "ERTS's heap sizes in words"), and its
      # depth with every element of a container counted as nested, as
      # InspectionBounds.funnel_depth counts it.
      Term = Data.define(:bytes, :words, :depth)
      # The three limits' floors for one set of receivers, keyed by the
      # runtime_limits field each binds.
      Floors = Data.define(:max_frame, :max_message_heap, :funnel_depth)

      module_function

      # The facet measures a request as erlang:external_size/1 does, which
      # counts the external format's version byte before the term.
      def request_max(modules_max:, piece_max:)
        requests = requests(modules_max: modules_max, piece_max: piece_max)
        1 + requests.map(&:bytes).max
      end

      def load_floors(modules_max:, piece_max:)
        floors(*load_messages(modules_max: modules_max, piece_max: piece_max))
      end

      def answer_floors(modules_max:, reasons:)
        floors(*answer_messages(modules_max: modules_max, reasons: reasons))
      end

      # A facet's floors bind its grantee and its server alike
      # (docs/design-domains.md, "Floors from a protocol"), so they count its
      # requests and its replies together.
      def facet_floors(modules_max:, piece_max:, reasons:)
        floors(*requests(modules_max: modules_max, piece_max: piece_max),
               *replies(modules_max: modules_max, reasons: reasons))
      end

      # The requests of the interface's facets in their gen_server call
      # envelope: a load into the system domain and into a named domain, a
      # reset and a put. A missing request names at most a load's hashes,
      # which the load's manifest outweighs, so it is not counted. A domain is
      # named by a binary of at most a name's bytes.
      def requests(modules_max:, piece_max:)
        manifest = list(tuple(module_name, blob_hash), modules_max)
        [tuple(atom('load'), manifest),
         tuple(atom('load'), domain_name, manifest),
         tuple(atom('reset'), domain_name),
         tuple(atom('put'), blob_hash, integer(U64_MAX), integer(U64_MAX),
               binary(piece_max))]
          .map do |request|
            tuple(atom('$gen_call'), tuple(pid, alias_tag), request)
          end
      end

      # The replies to those requests as gen_server delivers them,
      # {Tag, Reply}: the hashes a missing request lacks, and a load that
      # names every module it failed to load, the larger of the two refusals
      # that list a load's entries.
      def replies(modules_max:, reasons:)
        [tuple(atom('ok'), list(blob_hash, modules_max)),
         tuple(atom('error'), not_loaded(modules_max, reasons))]
          .map { |reply| tuple(alias_tag, reply) }
      end

      # The messages from erx_code to a code server: a load, a piece and the
      # word of publication, whose lifeline is counted as the larger of a pid
      # and an alias.
      def load_messages(modules_max:, piece_max:)
        entry = tuple(module_name, blob_hash, integer(U64_MAX))
        [tuple(atom('erx_code_load'), ref, list(entry, modules_max)),
         tuple(atom('erx_code_piece'), ref, blob_hash, integer(U64_MAX),
               binary(piece_max)),
         tuple(atom('erx_code_published'), ref, ref)]
      end

      # The messages from a code server to the system domain: its report, a
      # request for a piece and an answer that names every module of a load.
      def answer_messages(modules_max:, reasons:)
        refusal = tuple(atom('error'), not_loaded(modules_max, reasons))
        [tuple(atom('erx_code_agent'), pid),
         tuple(atom('erx_code_get'), ref, blob_hash, integer(U64_MAX)),
         tuple(atom('erx_code_loaded'), ref, refusal)]
      end

      # {not_loaded, [{Name, What}]} for every module of a load, What the
      # longest of REASONS, the code_load_reason enum's members, the only
      # reasons an answer carries.
      def not_loaded(modules_max, reasons)
        what = atom(reasons.max_by(&:bytesize))
        tuple(atom('not_loaded'), list(tuple(module_name, what), modules_max))
      end

      # Each limit's floor over MESSAGES: a frame's payload is the version byte
      # and the message.
      def floors(*messages)
        Floors.new(max_frame: power_of_two(1 + messages.map(&:bytes).max),
                   max_message_heap: power_of_two(messages.map(&:words).max),
                   funnel_depth: power_of_two(messages.map(&:depth).max))
      end

      def power_of_two(value) = 1 << (value - 1).bit_length

      def module_name = binary(NAME_MAX)

      def domain_name = binary(NAME_MAX)

      def blob_hash = binary(HASH_BYTES)

      # gen_server's call tag, [alias | Ref].
      def alias_tag = list(atom('alias'), 1, tail: ref)

      def atom(text)
        Term.new(bytes: InspectionBounds.atom_size(text), words: 0, depth: 0)
      end

      # A heap binary of up to 64 bytes, a reference and a sub-binary past
      # that.
      def binary(bytes)
        words = bytes <= 64 ? 2 + ((bytes + 7) / 8) : 8
        Term.new(bytes: 5 + bytes, words: words, depth: 0)
      end

      # A small integer is immediate; a larger one is a bignum of a header word
      # and its magnitude's bytes in whole words.
      def integer(value)
        magnitude = (value.bit_length + 7) / 8
        words = value > SMALL_MAX ? 1 + ((magnitude + 7) / 8) : 0
        Term.new(bytes: InspectionBounds.integer_size(value), words: words,
                 depth: 0)
      end

      # NEW_PID_EXT, and NEWER_REFERENCE_EXT with five ID words, one more than
      # the funnel admits (ERX_ETF_REF_WORDS), so the bound holds for the
      # longest reference ERTS writes; on the heap the funnel counts a pid as 4
      # words and a reference as 6 (liberx/erx_etf.c, WORDS_PID and WORDS_REF).
      def pid = Term.new(bytes: 1 + node.bytes + 12, words: 4, depth: 0)

      def ref
        Term.new(bytes: 1 + 2 + node.bytes + 4 + (4 * 5), words: 6, depth: 0)
      end

      def node = atom('x' * NAME_MAX)

      # NIL_EXT, a proper list's tail.
      def nil_tail = Term.new(bytes: 1, words: 0, depth: 0)

      def tuple(*elements)
        bytes = InspectionBounds.tuple_size(*elements.map(&:bytes))
        Term.new(bytes: bytes, words: 1 + elements.size + elements.sum(&:words),
                 depth: 1 + elements.map(&:depth).max)
      end

      # LIST_EXT of COUNT copies of ELEMENT, ended by TAIL, nil unless the list
      # is improper.
      def list(element, count, tail: nil_tail)
        Term.new(bytes: 5 + (count * element.bytes) + tail.bytes,
                 words: (count * (2 + element.words)) + tail.words,
                 depth: 1 + [element.depth, tail.depth].max)
      end
    end
  end
end
