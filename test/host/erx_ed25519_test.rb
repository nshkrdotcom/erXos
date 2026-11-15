# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'openssl'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'

# erx_ed25519_check (otp/erts/emulator/nifs/erxos/erx_ed25519.c over the imported Monocypher),
# the core of erx_bytes:ed25519_verify/3, against oracles that share no code with it: RFC
# 8032's test vectors (test/fixtures/ed25519_rfc8032.txt), the host's OpenSSL, which signs
# seeded random messages and judges every request the check judges, and Curve below, which
# builds the signatures over non-canonical and small-order points that design-ssh.md's
# acceptance rules decide. test/fixtures/ed25519_driver.c runs the C code; seeded faults in
# it must fail the same checks.
class ErxEd25519Test < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'otp/erts/emulator/nifs/erxos/erx_ed25519.c'
  SOURCES = [CORE, 'monocypher/monocypher.c', 'monocypher/monocypher-ed25519.c'].freeze
  # The core includes Monocypher by its path in the tree; a mutant's copy of a Monocypher
  # file, outside it, finds monocypher.h by the second.
  INCLUDES = ['.', 'monocypher', File.dirname(CORE)].freeze
  VECTORS = File.join(ROOT, 'test/fixtures/ed25519_rfc8032.txt')
  # The group's order, L, of RFC 8032 section 5.1.
  ORDER = 2**252 + 27_742_317_777_372_353_535_851_937_790_883_648_493
  # Message lengths at and around SHA-512's block and padding boundaries, and the most a call
  # takes, ERX_BYTES_CALL_MAX.
  LENGTHS = [0, 1, 63, 64, 65, 111, 112, 127, 128, 129, 1000, 65_535, 65_536].freeze
  SEED = 20_261_115

  Vector = Data.define(:name, :secret, :public, :message, :signature)
  # One request: what the check is asked and what it must answer.
  Request = Data.define(:signature, :key, :message, :valid)
  # A seeded fault: source with original replaced, which accepts every request of caught_by.
  Fault = Data.define(:source, :original, :replacement, :caught_by)

  def setup
    @directory = Dir.mktmpdir('erx-ed25519-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported ed25519-test sanitizer' unless (sanitizers - %w[address undefined]).empty?

    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    @driver = build(SOURCES.map { |source| File.join(ROOT, source) }, name: 'driver')
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  # Each vector is the RFC's: OpenSSL derives its public key from its secret and signs its
  # message to its signature, so the file is read right, and the check accepts it.
  def test_rfc8032_vectors_are_accepted
    assert_equal 5, vectors.size
    vectors.each do |vector|
      key = OpenSSL::PKey.new_raw_private_key('ED25519', vector.secret)
      assert_equal vector.public, key.raw_public_key, vector.name
      assert_equal vector.signature, key.sign(nil, vector.message), vector.name
    end
    assert_equal ['1'] * vectors.size, ask(vectors.map { |vector| request(vector.signature, vector.public, vector.message) })
  end

  # A bit flipped anywhere in a vector's signature, key or message, a byte added to or cut
  # from its message, a signature with S + L for S, and one or a key of the wrong length are
  # all refused, as OpenSSL refuses each of the right length.
  def test_altered_vectors_are_refused
    requests = vectors.flat_map { |vector| altered(vector) }
    requests.each { |item| refute openssl_verify(item), 'OpenSSL accepts an altered vector' if sized?(item) }
    assert_equal ['0'] * requests.size, ask(requests.map { |item| request(item.signature, item.key, item.message) })
  end

  # Seeded random keys and messages of every boundary length, each signed by OpenSSL, then
  # sent as signed and with one random bit flipped in the signature, the key or the message:
  # the check answers as OpenSSL does on every one.
  def test_agrees_with_openssl
    random = Random.new(SEED)
    requests = LENGTHS.flat_map do |length|
      key = OpenSSL::PKey.new_raw_private_key('ED25519', random.bytes(32))
      message = random.bytes(length)
      signature = key.sign(nil, message)
      signed = Request.new(signature: signature, key: key.raw_public_key, message: message, valid: true)
      [signed, *%i[signature key message].filter_map { |field| flipped(signed, field, random) }]
    end
    answers = ask(requests.map { |item| request(item.signature, item.key, item.message) })
    assert_equal(requests.map { |item| openssl_verify(item) ? '1' : '0' }, answers)
    assert_equal(requests.map { |item| item.valid ? '1' : '0' }, answers)
  end

  # Curve's arithmetic is RFC 8032's: it derives each vector's public key from its secret.
  def test_curve_derives_the_rfc8032_public_keys
    vectors.each do |vector|
      digest = OpenSSL::Digest::SHA512.digest(vector.secret)
      scalar = Curve.integer(digest.byteslice(0, 32)) & ((2**254) - 8) | (2**254)
      assert_equal vector.public, Curve.encode(Curve.multiply(Curve::BASE, scalar)), vector.name
    end
  end

  # The key and R must each be the canonical encoding of their point (design-ssh.md, "The
  # verifier's acceptance rules"). Every pair below is a signature that Monocypher's check
  # alone accepts with a non-canonical key or R, refused, and the same point's canonical
  # encoding signed the same way, accepted, so the encoding alone is what is refused.
  def test_non_canonical_encodings_are_refused
    pairs = non_canonical_keys + non_canonical_rs
    answers = ask(pairs.flat_map { |refused, accepted| [refused, accepted] }.map { |item| request(item.signature, item.key, item.message) })
    assert_equal ['0', '1'] * pairs.size, answers
  end

  # Monocypher's group equation is the cofactored one of RFC 8032 section 5.1.7, [8][S]B =
  # [8]R + [8][k]A, which design-ssh.md allows: a key with a component of order 2 and a k that
  # is odd leave [S]B - R - [k]A a point of order 2, which the cofactorless equation refuses
  # and the check accepts.
  def test_the_group_equation_is_cofactored
    item, residue = cofactor_signature
    refute_equal Curve::IDENTITY, residue, 'the cofactorless equation must fail'
    assert_equal Curve::IDENTITY, Curve.multiply(residue, 8)
    assert_equal ['1'], ask(request(item.signature, item.key, item.message))
  end

  # Seeded faults, each caught by the cases above: a check that lets S reach L, which accepts
  # the malleable signature; one that hashes no message, which accepts a signature over
  # another message; and one each without the key's and R's canonical encoding rule, which
  # accept the non-canonical signatures.
  def test_seeded_faults_are_caught
    vector = vectors.first
    other = Request.new(signature: vector.signature, key: vector.public, message: vectors.fetch(1).message, valid: false)
    faults = [Fault.new(source: 'monocypher/monocypher.c', original: 'is_above_l(s32)) {', replacement: '0) {',
                        caught_by: [malleable(vector)]),
              Fault.new(source: 'monocypher/monocypher-ed25519.c',
                        original: 'hash_reduce(h_ram, signature, 32, public_key, 32, msg, msg_size, 0, 0);',
                        replacement: 'hash_reduce(h_ram, signature, 32, public_key, 32, msg, msg_size - msg_size, 0, 0);',
                        caught_by: [other]),
              Fault.new(source: CORE, original: '!ed25519_canonical(key) || ', replacement: '',
                        caught_by: non_canonical_keys.map(&:first)),
              Fault.new(source: CORE, original: ' || !ed25519_canonical(signature)', replacement: '',
                        caught_by: non_canonical_rs.map(&:first))]
    faults.each_with_index do |fault, index|
      lines = fault.caught_by.map { |item| request(item.signature, item.key, item.message) }
      program = mutant(fault.source, fault.original, fault.replacement, index: index)
      assert_equal ['1'] * lines.size, ask(lines, program: program), fault.original
      assert_equal ['0'] * lines.size, ask(lines), fault.original
    end
  end

  private

  # Ed25519's curve, -x^2 + y^2 = 1 + d x^2 y^2 over GF(p), in affine coordinates, as RFC 8032
  # section 5.1 defines it: slow, plain, and enough to build the signatures the tests need.
  module Curve
    P = (2**255) - 19
    D = (-121_665 * 121_666.pow(P - 2, P)) % P
    Point = Data.define(:x, :y)
    IDENTITY = Point.new(x: 0, y: 1)

    module_function

    def integer(bytes) = bytes.reverse.unpack1('H*').to_i(16)

    def bytes(integer) = [integer.to_s(16).rjust(64, '0')].pack('H*').reverse

    def inverse(value) = value.pow(P - 2, P)

    # The point with y and the sign of x that RFC 8032 section 5.1.3 decodes.
    def point(y, sign)
      square = (y * y - 1) * inverse(D * y * y + 1) % P
      x = square.pow((P + 3) / 8, P)
      x = x * 2.pow((P - 1) / 4, P) % P unless (x * x - square) % P == 0
      raise Erx::Error, "no point has y = #{y}" unless (x * x - square) % P == 0

      Point.new(x: x.odd? == (sign == 1) ? x : (P - x) % P, y: y)
    end

    def add(a, b)
      t = D * a.x * b.x * a.y * b.y % P
      Point.new(x: (a.x * b.y + a.y * b.x) * inverse(1 + t) % P, y: (a.y * b.y + a.x * b.x) * inverse(1 - t) % P)
    end

    def negate(point) = Point.new(x: (P - point.x) % P, y: point.y)

    def multiply(point, scalar)
      scalar.to_s(2).each_char.reduce(IDENTITY) do |sum, bit|
        doubled = add(sum, sum)
        bit == '1' ? add(doubled, point) : doubled
      end
    end

    # The canonical encoding of point: y, with x's parity in the top bit.
    def encode(point) = bytes(point.y | ((point.x & 1) << 255))

    BASE = point(4 * inverse(5) % P, 0)
  end

  MESSAGE = 'erx'.b
  # The secret scalar and the nonce of the signatures built below, both below L.
  SECRET = (2**200) + 12_345
  NONCE = (2**201) + 6_789
  # Encodings of the points whose x is 0, the neutral point (0, 1) and (0, p - 1), and of
  # the point whose y is 0, each non-canonical, with its canonical encoding.
  NON_CANONICAL = [[Curve::P + 1, 1], [1 | (2**255), 1], [(Curve::P - 1) | (2**255), Curve::P - 1],
                   [Curve::P, 0]].freeze

  # Pairs of a signature by a non-canonical encoding of a key of small order, and the same by
  # its canonical encoding: R is [NONCE]B and S is NONCE, so [S]B - R - [k]A is -[k]A, of
  # small order, whatever k is.
  def non_canonical_keys
    signature = Curve.encode(Curve.multiply(Curve::BASE, NONCE)) + Curve.bytes(NONCE)
    NON_CANONICAL.map do |refused, accepted|
      [Request.new(signature: signature, key: Curve.bytes(refused), message: MESSAGE, valid: false),
       Request.new(signature: signature, key: Curve.bytes(accepted), message: MESSAGE, valid: true)]
    end
  end

  # Pairs of a signature by [SECRET]B whose R is a non-canonical encoding of a point of small
  # order, and the same with R's canonical encoding: S is k SECRET, so [S]B - R - [k]A is -R.
  def non_canonical_rs
    key = Curve.encode(Curve.multiply(Curve::BASE, SECRET))
    NON_CANONICAL.map do |refused, accepted|
      [refused, accepted].map do |r|
        encoding = Curve.bytes(r)
        Request.new(signature: encoding + Curve.bytes(challenge(encoding, key, MESSAGE) * SECRET % ORDER), key: key,
                    message: MESSAGE, valid: r == accepted)
      end
    end
  end

  # A signature by A = [SECRET]B + (0, p - 1), over the first message whose k is odd, and
  # [S]B - R - [k]A, which is then (0, p - 1).
  def cofactor_signature
    key = Curve.add(Curve.multiply(Curve::BASE, SECRET), Curve::Point.new(x: 0, y: Curve::P - 1))
    r = Curve.multiply(Curve::BASE, NONCE)
    message, k = (0..).lazy.map { |index| "erx#{index}".b }
                      .map { |text| [text, challenge(Curve.encode(r), Curve.encode(key), text)] }
                      .find { |_, value| value.odd? }
    s = (NONCE + k * SECRET) % ORDER
    residue = Curve.add(Curve.add(Curve.multiply(Curve::BASE, s), Curve.negate(r)),
                        Curve.negate(Curve.multiply(key, k)))
    [Request.new(signature: Curve.encode(r) + Curve.bytes(s), key: Curve.encode(key), message: message, valid: true),
     residue]
  end

  # RFC 8032's k: SHA-512 of R, the key and the message, little-endian, modulo L.
  def challenge(r, key, message) = Curve.integer(OpenSSL::Digest::SHA512.digest(r + key + message)) % ORDER

  def vectors
    @vectors ||= File.readlines(VECTORS, chomp: true).reject { |line| line.start_with?('#') }.map do |line|
      name, secret, public, message, signature = line.split(' ')
      Vector.new(name: name, secret: unhex(secret), public: unhex(public), message: unhex(message),
                 signature: unhex(signature))
    end
  end

  def altered(vector)
    signed = Request.new(signature: vector.signature, key: vector.public, message: vector.message, valid: true)
    bits = [[:signature, 0], [:signature, 31 * 8 + 7], [:signature, 32 * 8], [:signature, 63 * 8 + 7],
            [:key, 0], [:key, 31 * 8 + 6]]
    bits += [[:message, 0], [:message, vector.message.bytesize * 8 - 1]] unless vector.message.empty?
    [*bits.map { |field, bit| flip(signed, field, bit) },
     signed.with(message: vector.message + "\0".b, valid: false),
     *(vector.message.empty? ? [] : [signed.with(message: vector.message.byteslice(0...-1), valid: false)]),
     malleable(vector),
     signed.with(signature: vector.signature.byteslice(0, 63), valid: false),
     signed.with(key: vector.public + "\0".b, valid: false)]
  end

  # The vector's signature with S + L for S, which still fits S's 32 bytes, so only the check
  # that S is below L refuses it.
  def malleable(vector)
    s = vector.signature.byteslice(32, 32).reverse.unpack1('H*').to_i(16) + ORDER
    raise Erx::Error, 'S + L does not fit' unless s < 2**256

    Request.new(signature: vector.signature.byteslice(0, 32) + [s.to_s(16).rjust(64, '0')].pack('H*').reverse,
                key: vector.public, message: vector.message, valid: false)
  end

  def flipped(signed, field, random)
    size = signed.public_send(field).bytesize
    size.zero? ? nil : flip(signed, field, random.rand(size * 8))
  end

  def flip(signed, field, bit)
    bytes = signed.public_send(field).dup
    bytes.setbyte(bit / 8, bytes.getbyte(bit / 8) ^ (1 << (bit % 8)))
    signed.with(field => bytes, valid: false)
  end

  def sized?(item) = item.signature.bytesize == 64 && item.key.bytesize == 32

  def openssl_verify(item)
    OpenSSL::PKey.new_raw_public_key('ED25519', item.key).verify(nil, item.signature, item.message)
  rescue OpenSSL::PKey::PKeyError
    false
  end

  def request(signature, key, message) = [signature, key, message].map { |bytes| hex(bytes) }.join(' ')

  def hex(bytes) = bytes.empty? ? '-' : bytes.unpack1('H*')

  def unhex(text) = text == '-' ? ''.b : [text].pack('H*')

  def ask(requests, program: @driver)
    requests = Array(requests)
    input = File.join(@directory, 'requests.txt')
    File.write(input, requests.map { |line| "#{line}\n" }.join)
    record = @runner.run([program, input], name: 'ed25519-driver', deadline: 300)
    File.readlines(record.fetch('log'), chomp: true).tap do |lines|
      raise Erx::Error, "#{lines.size} answers to #{requests.size} requests" unless lines.size == requests.size
    end
  end

  # A driver built with source replaced by a copy in which original, which must occur exactly
  # once, reads replacement.
  def mutant(source, original, replacement, index:)
    text = File.read(File.join(ROOT, source))
    raise Erx::Error, "mutant must edit exactly one place in #{source}" unless text.scan(original).size == 1

    path = File.join(@directory, "mutant-#{index}-#{File.basename(source)}")
    File.write(path, text.sub(original) { replacement })
    build(SOURCES.map { |name| name == source ? path : File.join(ROOT, name) }, name: "mutant-#{index}")
  end

  def build(sources, name:)
    output = File.join(@directory, name)
    @runner.run([ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                 *@sanitizer_flags, *INCLUDES.flat_map { |directory| ['-I', File.join(ROOT, directory)] }, *sources,
                 File.join(ROOT, 'test/fixtures/ed25519_driver.c'), '-o', output],
                name: "compile-#{name}", deadline: 120)
    output
  end
end
