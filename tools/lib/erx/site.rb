# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'socket'
require 'tmpdir'
require 'zlib'
require_relative 'book'
require_relative 'boot_partition'
require_relative 'bounded_file'
require_relative 'error'
require_relative 'image_record'
require_relative 'json_input'
require_relative 'medium_image'
require_relative 'site_v64'
require_relative 'web_build'

module Erx
  # Assembles the static website in build/site from six inputs: the page
  # sources in site/, a v64 tree SiteV64 built (the emulator the page runs
  # erXos on, with its license notices), xterm.js as `tools/erx fetch`
  # installed it from site/pnpm-lock.yaml (the console's terminal, with its
  # license), an erXos boot image with its build
  # record (ImageRecord), the Raspberry Pi 4's card with its own
  # (BootPartition), and the source both were built from. None of the built
  # files is checked in.
  #
  # It also makes the disk the page attaches to the machine as its virtio
  # block device, on the virtio-mmio slot where the QEMU harness attaches
  # its guest's: a boot medium laid out by abi/medium.txt whose windows are
  # blank but for the data partition's fresh littlefs volume (fresh_medium).
  # The medium is 718 MiB, but only its partition table and the volume's
  # first blocks hold bytes, so it is published as those bytes and the
  # extents they fill, and the page keeps it sparse.
  #
  # The image, the disk, terminal.js, v64's two files and xterm.js's two are
  # stored under names that carry their digests, and boot.json (fetched without the
  # cache's copy) and index.html name them, so a cache never serves a stale
  # file and files of two deployments never mix. The image is gzip-compressed; the
  # page decompresses it with DecompressionStream, so the static host needs
  # no Content-Encoding setup. The same file is the page's QEMU virt
  # download: QEMU's -kernel takes a gzip-compressed image as it is.
  #
  # The card is a download, xz-compressed as `make pack` compresses it
  # (BootPartition.compress). Its build record is published beside
  # it, once card_record finds it is the card's, of the commit the page
  # links with no changes, and names no host path.
  #
  # The image and the card carry GPL-2.0 code, the development Fiasco kernel's and the
  # board's device tree, so the page links the erXos source they were built
  # from, a release tag or a commit, beside each download (docs/design.md,
  # "Licenses and notices").
  module Site
    PAGE_FILES = %w[index.html release-notes.html style.css favicon.svg terminal.js kiosk.png doom.png fonts.css tokens.css
                    book.css].freeze
    # What marks a statement of a page source that no source in the tree confirms yet. A
    # page that holds one is a draft, and the site publishes no draft (CLAUDE.md, "Never
    # fabricate").
    UNVERIFIED = '<!-- unverified'
    MANIFEST = 'boot.json'
    # Marks a directory this step built; the server's route table skips it.
    MARKER = '.erx-site'
    REPOSITORY = 'https://github.com/stass/erXos'
    TAG = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,99}\z/
    COMMIT = /\A[0-9a-f]{40}\z/
    SECTOR_BYTES = MediumImage::SECTOR_BYTES
    # The console's packages, which `tools/erx fetch` installs from site/'s
    # package files (WebBuild.fetch): xterm.js alone.
    PACKAGES = WebBuild::Packages.new(name: 'site', title: "the website's console", source: 'site',
                                      modules: 'build/site-modules')
    XTERM_PACKAGE = 'node_modules/@xterm/xterm'
    # The files of the package the page loads, published under xterm/ by
    # their digests, and its license, published beside them as it is.
    XTERM = { 'xterm.js' => 'lib/xterm.js', 'xterm.css' => 'css/xterm.css' }.freeze
    XTERM_NOTICES = { 'LICENSE.txt' => 'LICENSE' }.freeze

    # One output file: where it goes under the site directory, where it comes
    # from, and how it is stored: as it is (nil), :gzip or :xz.
    Entry = Data.define(:path, :source, :compression)
    # Third-party files published under directory/: each of files (its
    # name => its source) by its digest name, and each of notices (the name
    # it is published as => its source) as it is.
    Bundle = Data.define(:directory, :files, :notices) do
      def sources = [*files.values, *notices.values]
    end
    # A disk of capacity bytes that holds content at extents, [offset, length]
    # pairs in bytes, sorted, apart and whole sectors, whose lengths sum to
    # content's; every other byte is zero.
    Disk = Data.define(:capacity, :extents, :content)
    # The erXos source an image was built from: a release tag or a commit.
    Source = Data.define(:ref) do
      def url = "#{REPOSITORY}/tree/#{ref}"
      def label = COMMIT.match?(ref) ? ref[0, 12] : ref
    end
    # entries: the files copied as they are; index: index.html's template;
    # names: the digest names; disk: the Disk; manifest: boot.json without
    # the image's and the card's compressed_bytes and compressed_sha256,
    # which only the written files give; card_record: the
    # card's build record as card_record checked it, which is what is
    # published, so no byte of the file goes out unchecked.
    # shared_names: the published names of the shared stylesheets
    # (Book.shared_files), which index.html and release-notes.html link;
    # release_notes: that page's template.
    Plan = Data.define(:entries, :index, :release_notes, :names, :shared_names, :disk, :manifest, :card_record)

    module_function

    # A release tag (letters, digits, '.', '_' and '-', no '..') or a full
    # commit hash; anything else is refused, since it lands in a URL and in
    # the page.
    def source(ref)
      unless ref.is_a?(String) && (COMMIT.match?(ref) || (TAG.match?(ref) && !ref.include?('..')))
        raise Error, "image source must be a release tag or a 40-hex commit: #{ref.inspect}"
      end

      Source.new(ref:)
    end

    # The name under which a file is published: its digest's first 16 hex
    # digits before its extension.
    def digest_name(name, digest)
      extension = File.extname(name)
      "#{File.basename(name, extension)}-#{digest[0, 16]}#{extension}"
    end

    # The disk of capacity bytes that pieces, a map from a sector to the
    # bytes written from it (whole sectors), fill: each run of adjacent
    # pieces is one extent. Raises Erx::Error for a piece that is not whole
    # sectors within the disk or that overlaps another.
    def disk(pieces:, capacity:)
      unless capacity.is_a?(Integer) && capacity.positive? && (capacity % SECTOR_BYTES).zero?
        raise Error, 'a disk is a positive whole number of sectors'
      end

      spans = pieces.map { |sector, bytes| disk_span(sector, bytes, capacity:) }.sort_by(&:first)
      spans.each_cons(2) do |(offset, length), (next_offset, _)|
        raise Error, "the disk's piece at byte #{next_offset} overlaps the one before it" if offset + length > next_offset
      end
      runs = spans.slice_when { |(offset, length), (next_offset, _)| offset + length != next_offset }
      Disk.new(capacity:, extents: runs.map { |run| [run.first.first, run.sum(&:last)].freeze }.freeze,
               content: pieces.sort_by(&:first).map(&:last).join.b.freeze)
    end

    # A piece's [offset, length] in bytes, once it is found to be whole
    # sectors within a disk of capacity bytes.
    def disk_span(sector, bytes, capacity:)
      unless sector.is_a?(Integer) && !sector.negative? && bytes.is_a?(String) && !bytes.empty? &&
             (bytes.bytesize % SECTOR_BYTES).zero? && (sector * SECTOR_BYTES) + bytes.bytesize <= capacity
        raise Error, "the disk's piece at sector #{sector.inspect} is not whole sectors within the disk"
      end

      [sector * SECTOR_BYTES, bytes.bytesize]
    end
    private_class_method :disk_span

    # The data partition's length on the page's disk, a medium as packed.
    def data_sectors = MediumImage::PACKED_DATA_SECTORS

    # The disk the page attaches: a boot medium of data_sectors whose windows
    # are blank but for the data partition, which holds volume, the bytes of
    # a fresh littlefs volume of that partition (DataVolume.format). Making
    # the disk is the page's installation, the one step that formats /data,
    # since the guest's mount never does. erx_blk_table admits it. Only the
    # partition table's five records and the volume hold bytes.
    def fresh_medium(volume:)
      pieces = MediumImage.records(data_sectors:).merge(MediumImage.constant('data_start') => volume)
      disk(pieces:, capacity: MediumImage.sectors(data_sectors:) * SECTOR_BYTES)
    end

    # The card's build record, parsed from the bytes of a BootPartition
    # receipt, once it names sha256 as its card's, names commit as the one
    # the card was built from with no changes, and holds no absolute path
    # (BootPartition.check_record). The page links commit as the card's
    # source, so a record of another card or commit, of a changed tree, of a
    # tree that was no checkout, or one that would publish a host's paths, is
    # refused.
    def card_record(bytes, sha256:, commit:)
      record = JsonInput.parse(bytes, max_bytes: BootPartition::RECORD_BYTES, label: "the card's build record")
      artifact = { 'path' => BootPartition::IMAGE, 'sha256' => sha256 }
      unless record.is_a?(Hash) && record['artifact'] == artifact
        raise Error, "the card's build record is not of this card, #{BootPartition::IMAGE} with SHA-256 #{sha256}"
      end
      unless record['source'] == { 'commit' => commit, 'dirty' => false }
        raise Error, "the card's build record does not name #{commit}, with no changes, as the source it was built from"
      end

      BootPartition.check_record(record)
    end

    # Reads the inputs' sizes and digests and decides which file goes where.
    # Raises Erx::Error naming the first missing input, for an image whose
    # build record (image_record) does not let it be published
    # (ImageRecord.check), or for a card whose build record is not its own or
    # not of source (card_record). Both records name the commit they were
    # built from, so source must be a commit, not a tag, which they cannot be
    # checked against here (the workflow resolves its tag to the commit). card
    # and card_record are both paths or both nil; nil is a build without the
    # Raspberry Pi 4's card, for a local preview (tools/build_site.rb
    # --no-card), whose page has no card section and whose boot.json has no
    # card entry; the image is checked the same with a card or without.
    def inventory(root:, v64:, image:, image_record:, card:, card_record:, source:, disk:, shared_names:)
      raise Error, 'the card and its build record are given both or neither' unless card.nil? == card_record.nil?
      unless COMMIT.match?(source.ref)
        raise Error, "the image's source must be given as its 40-hex commit, which its build records name, not #{source.ref}"
      end

      unless WebBuild.fetched?(root:, packages: PACKAGES)
        raise Error, "#{PACKAGES.title}'s packages are not installed for site/'s package files; " \
                     "run `tools/erx fetch --packages #{PACKAGES.name}`"
      end

      page = PAGE_FILES.to_h { |name| [name, File.join(root, 'site', name)] }
      xterm_package = File.join(root, PACKAGES.modules, XTERM_PACKAGE)
      bundles = { v64: bundle('v64', SiteV64::TARGETS, SiteV64::NOTICES, under: v64),
                  xterm: bundle('xterm', XTERM, XTERM_NOTICES, under: xterm_package) }
      missing = [*page.values, *bundles.values.flat_map(&:sources), image, image_record, card, card_record]
                .compact.reject { |path| File.file?(path) }
      raise Error, "site input missing: #{missing.first}" unless missing.empty?

      draft = page.keys.find { |name| File.read(page.fetch(name)).include?(UNVERIFIED) }
      raise Error, "site/#{draft} holds a statement marked #{UNVERIFIED}; settle it before publishing" if draft

      page.each { |name, path| remote_load("site/#{name}", File.read(path)) }
      bundles.fetch(:xterm).files.each { |name, path| remote_load("xterm/#{name}", File.read(path)) }
      digest = ->(path) { Digest::SHA256.file(path).hexdigest }
      image_sha256 = digest.(image)
      ImageRecord.check(BoundedFile.read(image_record, maximum: ImageRecord::MAX_BYTES), sha256: image_sha256, commit: source.ref)
      disk_sha256 = Digest::SHA256.hexdigest(disk.content)
      card_sha256 = card && digest.(card)
      record = card && card_record(BoundedFile.read(card_record, maximum: BootPartition::RECORD_BYTES), sha256: card_sha256, commit: source.ref)
      names = { 'terminal.js' => digest_name('terminal.js', digest.(page.fetch('terminal.js'))),
                'image' => "image-#{image_sha256[0, 16]}.boot.gz", 'disk' => "disk-#{disk_sha256[0, 16]}.bin" }
              .merge(card ? { 'card' => "sdcard-#{card_sha256[0, 16]}.img.xz",
                              'card_record' => "sdcard-#{card_sha256[0, 16]}.img.receipt.json" } : {})
              .merge(*bundles.values.map { |bundle| bundle.files.to_h { |name, path| [name, "#{bundle.directory}/#{digest_name(name, digest.(path))}"] } })
      entries = [Entry.new(path: 'style.css', source: page.fetch('style.css'), compression: nil),
                 Entry.new(path: 'favicon.svg', source: page.fetch('favicon.svg'), compression: nil),
                 *%w[kiosk.png doom.png].map { |name| Entry.new(path: name, source: page.fetch(name), compression: nil) },
                 Entry.new(path: names.fetch('terminal.js'), source: page.fetch('terminal.js'), compression: nil),
                 *bundles.values.flat_map { |bundle| bundle_entries(bundle, names) },
                 Entry.new(path: names.fetch('image'), source: image, compression: :gzip),
                 *(Entry.new(path: names.fetch('card'), source: card, compression: :xz) if card)]
      manifest = { image: names.fetch('image'), bytes: File.size(image), sha256: image_sha256,
                   emulator: { module: names.fetch('libv86.mjs'), wasm: names.fetch('v86-arm64.wasm'),
                               bytes: bundles.fetch(:v64).files.values.sum { |path| File.size(path) } },
                   terminal: { script: names.fetch('xterm.js'), stylesheet: names.fetch('xterm.css') },
                   disk: { file: names.fetch('disk'), bytes: disk.content.bytesize, sha256: disk_sha256,
                           capacity: disk.capacity, extents: disk.extents },
                   source: { ref: source.ref, url: source.url } }
      if card
        manifest[:card] = { file: names.fetch('card'), bytes: File.size(card), sha256: card_sha256,
                            record: names.fetch('card_record') }
      end
      Plan.new(entries:, index: page.fetch('index.html'), release_notes: page.fetch('release-notes.html'), names:,
               shared_names:, disk:, manifest:, card_record: record)
    end

    # The Bundle of files and notices (published name => path under
    # directory under) published under directory/.
    def bundle(directory, files, notices, under:)
      Bundle.new(directory:, files: files.transform_values { |path| File.join(under, path) },
                 notices: notices.transform_values { |path| File.join(under, path) })
    end
    private_class_method :bundle

    # bundle's entries: its files under the names names gives them, its notices as they are.
    def bundle_entries(bundle, names)
      [*bundle.files.map { |name, path| Entry.new(path: names.fetch(name), source: path, compression: nil) },
       *bundle.notices.map { |name, path| Entry.new(path: "#{bundle.directory}/#{name}", source: path, compression: nil) }]
    end
    private_class_method :bundle_entries

    # A load from another host in a page or a stylesheet: a link, script or
    # img element whose address has a scheme or begins with //, or a CSS
    # url() or @import that does. A link a reader follows (<a href>) is not
    # a load.
    MARKUP_LOAD = %r{<(?:link|script|img)\b[^>]*\s(?:href|src)\s*=\s*["']?(?:[A-Za-z][A-Za-z0-9+.-]*:|//)[^"'\s>]*|
                     url\(\s*["']?(?:[A-Za-z][A-Za-z0-9+.-]*:|//)[^)"']*|
                     @import\s+["'](?:[A-Za-z][A-Za-z0-9+.-]*:|//)[^"']*}xi
    # A script names no address of another host at all: a string or template
    # literal that begins with scheme:// or //. Whatever a script does with
    # such an address (a script or link element, fetch, import, a WebSocket),
    # it is the start of a load, and the links a reader follows are the
    # pages'. An address the script assembles from pieces is not seen; the
    # rule catches the address written out, as a pinned CDN copy is.
    SCRIPT_LOAD = %r{["'`](?:[A-Za-z][A-Za-z0-9+.-]*:)?//[^"'`\s]*}
    # The rule each kind of file the site publishes from a source is read
    # by, nil for a raster image, which loads nothing. A file of another
    # kind is refused until a rule for it is added here.
    REMOTE_LOADS = { '.html' => MARKUP_LOAD, '.css' => MARKUP_LOAD, '.svg' => MARKUP_LOAD, '.js' => SCRIPT_LOAD,
                     '.png' => nil }.freeze

    # Refuses a page, stylesheet, script or drawing (label names it) that
    # loads a resource from another host, which would tell that host who
    # reads the site (docs/design-book-site.md, requirement 7).
    def remote_load(label, text)
      kind = File.extname(label)
      raise Error, "#{label}: no rule says what a #{kind} file may load" unless REMOTE_LOADS.key?(kind)

      found = REMOTE_LOADS.fetch(kind)&.then { |rule| text[rule] }
      raise Error, "#{label} loads a resource from another host: #{found}" if found
    end

    # What index.html wraps its card section in: kept, without the markers,
    # for a build with a card and removed with it for one without.
    CARD_BLOCK = %r{<!--card-->(.*?)<!--/card-->\n?}m

    # A download's size as the page shows it, in decimal megabytes.
    def size_label(bytes) = format('%.1f MB', bytes / 1_000_000.0)

    # index.html with its {{name}} placeholders filled in. image is
    # boot.json's image fields: image, the published file, and its
    # compressed_bytes and compressed_sha256, which the QEMU virt download shows. card is
    # boot.json's card entry, or nil for a build without a card, which has
    # no card placeholder to fill. Every value goes through the site's one
    # HTML escaper, Book::Html.escape, which the book's pages use too; an unknown
    # placeholder raises, so a card placeholder outside the card section
    # fails a build without a card instead of reaching the page.
    def render_index(template, terminal:, source:, image:, card:, shared:)
      values = { 'terminal_js' => terminal, 'source_url' => source.url, 'source_label' => source.label,
                 'fonts_css' => shared.fetch(:fonts_css), 'tokens_css' => shared.fetch(:tokens_css),
                 'image_file' => image.fetch(:image), 'image_download_size' => size_label(image.fetch(:compressed_bytes)),
                 'image_download_sha256' => image.fetch(:compressed_sha256) }
      values.merge!('card_file' => card.fetch(:file), 'card_record' => card.fetch(:record),
                    'card_download_size' => size_label(card.fetch(:compressed_bytes)),
                    'card_download_sha256' => card.fetch(:compressed_sha256)) if card
      template = template.gsub(CARD_BLOCK) { card ? Regexp.last_match(1) : '' }
      template.gsub(/\{\{([a-z][a-z0-9_]*)\}\}/) do
        key = Regexp.last_match(1)
        raise Error, "index.html: unknown placeholder {{#{key}}}" unless values.key?(key)

        Book::Html.escape(values.fetch(key))
      end
    end

    # A page whose only placeholders are the shared stylesheets' names
    # (release-notes.html), filled as render_index fills them.
    def fill_shared(template, shared, label)
      template.gsub(/\{\{([a-z][a-z0-9_]*)\}\}/) do
        key = Regexp.last_match(1).to_sym
        raise Error, "#{label}: unknown placeholder {{#{key}}}" unless shared.key?(key)

        Book::Html.escape(shared.fetch(key))
      end
    end

    # The effects: builds the site (replace) and returns boot.json's
    # contents. book is the book's Book::Plan, published in the same tree,
    # so the book and the landing page go out together or not at all.
    # runner runs xz (Runner).
    def publish(plan, out:, runner:, book:)
      replace(out) do |site|
        Book.write(book, out: site)
        assemble(plan, out: site, runner:)
      end
    end

    # Builds a site tree in a fresh sibling of out (the block writes it into
    # the directory it is given) and only then replaces out with it, so a
    # refusal leaves out as it was. The replacement deletes the old tree and
    # renames the new one into place; an interruption between the two
    # leaves no out, which the next build writes. Only a directory a site
    # build made (it holds the MARKER file) is replaced, so a mistyped path
    # never deletes anything else. Returns the block's value.
    def replace(out)
      if File.exist?(out) && !File.file?(File.join(out, MARKER))
        raise Error, "refusing to replace #{out}: not built by a site build"
      end

      FileUtils.mkdir_p(File.dirname(out))
      Dir.mktmpdir('.site-', File.dirname(out)) do |staging|
        site = File.join(staging, 'site')
        Dir.mkdir(site)
        value = yield site
        File.write(File.join(site, MARKER), "built by a site build\n")
        FileUtils.rm_rf(out)
        File.rename(site, out)
        value
      end
    end

    # The tree's HEAD commit, which the site's source links and the book's
    # links into the repository name.
    def head(root:, runner:)
      File.read(runner.run(%W[git -C #{root} rev-parse HEAD], name: 'site-head', deadline: 30).fetch('log')).strip
    end

    def assemble(plan, out:, runner:)
      plan.entries.each { |entry| write(entry, out:, runner:) }
      File.binwrite(File.join(out, plan.names.fetch('disk')), plan.disk.content)
      card = plan.manifest[:card] && publish_card(plan, out:)
      manifest = plan.manifest.merge(download(File.join(out, plan.names.fetch('image'))))
      manifest[:card] = card if card
      index = render_index(File.read(plan.index), terminal: plan.names.fetch('terminal.js'),
                                                  source: Source.new(ref: plan.manifest.dig(:source, :ref)),
                                                  image: manifest.slice(:image, :compressed_bytes, :compressed_sha256), card:,
                                                  shared: plan.shared_names)
      File.write(File.join(out, 'index.html'), index)
      File.write(File.join(out, 'release-notes.html'), fill_shared(File.read(plan.release_notes), plan.shared_names, 'release-notes.html'))
      File.write(File.join(out, MANIFEST), "#{JSON.pretty_generate(manifest)}\n")
      manifest
    end
    private_class_method :assemble

    # The card's record beside its download, and the card's manifest entry
    # with the download's size and digest.
    def publish_card(plan, out:)
      File.write(File.join(out, plan.names.fetch('card_record')), "#{JSON.pretty_generate(plan.card_record)}\n")
      plan.manifest.fetch(:card).merge(download(File.join(out, plan.names.fetch('card'))))
    end
    private_class_method :publish_card

    # A written download's size and digest, which the page shows beside it.
    def download(path) = { compressed_bytes: File.size(path), compressed_sha256: Digest::SHA256.file(path).hexdigest }
    private_class_method :download

    def write(entry, out:, runner:)
      target = File.join(out, entry.path)
      FileUtils.mkdir_p(File.dirname(target))
      case entry.compression
      in nil
        FileUtils.cp(entry.source, target)
      in :gzip
        Zlib::GzipWriter.open(target, Zlib::BEST_COMPRESSION) do |gz|
          gz.mtime = 0 # the same image gives the same bytes
          File.open(entry.source, 'rb') { |input| IO.copy_stream(input, gz) }
        end
      in :xz
        BootPartition.compress(entry.source, to: target, runner: runner)
        File.chmod(0o644, target) # the runner creates its output owner-only; the site is public
      end
    end
    private_class_method :write

    CONTENT_TYPES = {
      '.html' => 'text/html; charset=utf-8', '.css' => 'text/css', '.svg' => 'image/svg+xml', '.png' => 'image/png',
      '.js' => 'text/javascript',
      '.mjs' => 'text/javascript', '.wasm' => 'application/wasm', '.json' => 'application/json',
      '.gz' => 'application/gzip', '.xz' => 'application/x-xz', '.bin' => 'application/octet-stream',
      '.woff2' => 'font/woff2', '.ttf' => 'font/ttf', '.txt' => 'text/plain; charset=utf-8'
    }.freeze

    # Maps each URL path to a file of the site directory, listed once at
    # start: a request names an entry of this table or gets 404, so no
    # request path ever reaches the file system. Every X/index.html also
    # answers /X/, as the static host does; / is the case where X is empty.
    # The MARKER is not served.
    def routes(dir)
      files = Dir.glob('**/*', base: dir).sort.select { |path| path != MARKER && File.file?(File.join(dir, path)) }
      files.to_h { |path| ["/#{path}", File.join(dir, path)] }
           .merge(files.select { |path| File.basename(path) == 'index.html' }
                       .to_h { |path| ["/#{File.dirname(path).delete_prefix('.')}/".squeeze('/'), File.join(dir, path)] })
    end

    # A minimal static server for viewing the site locally, bound to
    # 127.0.0.1 only. Runs until interrupted. It is a development tool: one
    # thread per connection, no limits on request size or time, so a client
    # on this machine can hang or exhaust it.
    def serve(dir:, port:)
      table = routes(dir)
      server = begin
        TCPServer.new('127.0.0.1', port)
      rescue SystemCallError => error
        raise Error, "cannot listen on 127.0.0.1:#{port}: #{error.message}"
      end
      puts "Site: http://127.0.0.1:#{port}/"
      loop { Thread.new(server.accept) { |client| answer(client, table) } }
    ensure
      server&.close
    end

    def answer(client, table)
      method, target = client.gets.to_s.b.split
      skip_headers(client)
      file = table[target.to_s.split('?').first] if %w[GET HEAD].include?(method)
      if file.nil?
        client.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        return
      end

      type = CONTENT_TYPES.fetch(File.extname(file), 'text/plain; charset=utf-8')
      client.write("HTTP/1.1 200 OK\r\nContent-Type: #{type}\r\nContent-Length: #{File.size(file)}\r\n" \
                   "Cache-Control: no-cache\r\nConnection: close\r\n\r\n")
      File.open(file, 'rb') { |input| IO.copy_stream(input, client) } if method == 'GET'
    rescue SystemCallError, IOError
      nil # the browser went away mid-response
    ensure
      client.close
    end
    private_class_method :answer

    # Reads the request's header lines up to the blank line that ends them.
    def skip_headers(client)
      loop do
        line = client.gets
        break if line.nil? || line.strip.empty?
      end
    end
    private_class_method :skip_headers
  end
end
