# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'rexml/document'
require 'set'
require_relative '../../tools/lib/erx/book'
require_relative '../../tools/lib/erx/site'

# The book renderer's pure core (docs/design-book-site.md, "Tests"): parse trees
# are written here in the shape cmark-gfm's XML gives, so these tests need no
# tool. Each test names the fault planted by hand that must fail it.
class BookTest < Minitest::Test
  COMMIT = 'c0ffee00' * 5
  REPO = Erx::Site::REPOSITORY

  # A parse tree with the given body, as cmark-gfm -t xml --sourcepos writes one.
  def tree(body)
    REXML::Document.new("<?xml version='1.0'?><document xmlns='http://commonmark.org/xml/1.0'>#{body}</document>")
  end

  def text(value, line = 1) = "<text sourcepos='#{line}:1-#{line}:9'>#{value.encode(xml: :text)}</text>"

  def resolver(anchors: {})
    files = { 'docs/book/02-microkernels.md' => :file, 'docs/book/16-storage.md' => :file, 'docs/design-kernel.md' => :file,
              'docs' => :directory, 'docs/book' => :directory, 'kernel' => :directory, 'site/kiosk.png' => :file }
    known = { 'docs/book/02-microkernels.md' => %w[25-the-l4-family-and-fiasco], 'docs/design-kernel.md' => %w[the-boot-image],
              'docs/book/16-storage.md' => %w[chapter-16-storage-and-updates] }.merge(anchors)
    Erx::Book::Links::Resolver.new(repository: REPO, commit: COMMIT,
                                   pages: { 'docs/book/02-microkernels.md' => '02-microkernels.html',
                                            'docs/book/16-storage.md' => '16-storage.html' },
                                   kind_of: files.method(:[]), anchors_of: ->(path) { known.fetch(path, []).to_set },
                                   digest_of: ->(_path) { 'ab' * 32 })
  end

  def render(body, path: 'docs/book/16-storage.md', drafts: false)
    document = tree(body)
    ids = Erx::Book::Links.slugs(document.root.get_elements('//heading').map { |node| node.elements.to_a.map(&:text).join })
    Erx::Book::Page.render(document, ids:, path:, resolver: resolver, drafts:)
  end

  TITLE = "<heading level='1' sourcepos='1:1-1:9'><text>Chapter 16. Storage and Updates</text></heading>"

  # Seeded faults: keep the dots (2.5-the-l4...); number repeats from 2 instead of 1.
  def test_slugs_follow_github
    headings = ['2.5 The L4 family and Fiasco', 'Chapter 16. Storage and Updates', '16.2.3 The `system` tree, and every reader',
                "erXos's F2FS", 'What fails: and what it reaches', 'Summary', 'Summary', 'Summary', 'A_b - c']
    assert_equal %w[25-the-l4-family-and-fiasco chapter-16-storage-and-updates 1623-the-system-tree-and-every-reader
                    erxoss-f2fs what-fails-and-what-it-reaches summary summary-1 summary-2 a_b---c],
                 Erx::Book::Links.slugs(headings.map { |heading| heading.delete('`') })
  end

  # Seeded faults: resolve repository paths from docs/book/ instead of the root;
  # pass a target through unchanged when its scheme is https.
  def test_links_resolve_to_built_addresses
    from = 'docs/book/16-storage.md'
    links = resolver
    assert_equal '02-microkernels.html#25-the-l4-family-and-fiasco',
                 links.link('02-microkernels.md#25-the-l4-family-and-fiasco', from:, line: 3).to_s
    assert_equal "#{REPO}/blob/#{COMMIT}/docs/design-kernel.md#the-boot-image",
                 links.link('../design-kernel.md#the-boot-image', from:, line: 3).to_s
    assert_equal "#{REPO}/tree/#{COMMIT}/kernel", links.link('../../kernel', from:, line: 3).to_s
    assert_equal 'https://example.org/a?b=c#d', links.link('https://EXAMPLE.org/a?b=c#d', from:, line: 3).to_s
    assert_equal '#chapter-16-storage-and-updates', links.link('#chapter-16-storage-and-updates', from:, line: 3).to_s
  end

  def test_links_refuse_with_file_and_line
    from = 'docs/book/16-storage.md'
    ['../design-kernel.md#nonesuch', 'missing.md', '../../../etc/passwd', 'http://example.org/', 'javascript:alert(1)',
     '//example.org/x', 'https://user@example.org/', 'mailto:a@example.org', '#nonesuch'].each do |target|
      error = assert_raises(Erx::Error, target) { resolver.link(target, from:, line: 7) }
      assert_includes error.message, "#{from}:7: link #{target.inspect}"
    end
  end

  def test_images_go_to_media_under_digest_names
    address, file = resolver.image('../../site/kiosk.png', from: 'docs/book/22-display.md', line: 4)
    assert_equal ["media/#{'ab' * 8}-kiosk.png", 'site/kiosk.png'], [address.to_s, file]
    assert_raises(Erx::Error) { resolver.image('https://example.org/x.png', from: 'docs/book/22-display.md', line: 4) }
  end

  OUTLINE = <<~XML
    <heading level='2' sourcepos='1:1-1:9'><text>Contents</text></heading>
    <paragraph sourcepos='2:1-2:9'><strong><text>Part I. Background</text></strong></paragraph>
    <list type='ordered' start='1' tight='true'>
      <item><paragraph><link destination='#chapter-2-microkernels-and-capabilities' sourcepos='3:1-3:9'><text>Microkernels</text></link></paragraph></item>
      <item><paragraph><link destination='#chapter-3-erlang-and-otp' sourcepos='4:1-4:9'><text>Erlang</text></link></paragraph></item>
    </list>
    <paragraph sourcepos='6:1-6:9'><strong><text>Part II. Overview</text></strong></paragraph>
    <list type='ordered' start='4' tight='true'>
      <item><paragraph><link destination='#chapter-16-storage-and-updates' sourcepos='7:1-7:9'><text>Storage</text></link></paragraph></item>
    </list>
    <paragraph sourcepos='9:1-9:9'><strong><text>Appendices.</text></strong><text> </text><link destination='#appendix-a-glossary' sourcepos='9:1-9:9'><text>A. Glossary</text></link></paragraph>
    <heading level='2' sourcepos='10:1-10:9'><text>Part I</text></heading>
  XML

  # Seeded faults: take a link's part from the following bold paragraph; drop the
  # unreferenced-file check.
  def test_contents_derive_parts_unwritten_entries_and_neighbours
    titles = { 'chapter-2-microkernels-and-capabilities' => '02-microkernels.html',
               'chapter-16-storage-and-updates' => '16-storage.html', 'appendix-a-glossary' => 'a-glossary.html' }
    entries = Erx::Book::Contents.derive(tree(OUTLINE), titles:, path: 'docs/book/README.md')
    assert_equal [['Part I. Background', 'Microkernels', '2', '02-microkernels.html'], ['Part I. Background', 'Erlang', '3', nil],
                  ['Part II. Overview', 'Storage', '16', '16-storage.html'], ['Appendices', 'Glossary', 'A', 'a-glossary.html']],
                 entries.map { |entry| [entry.part, entry.title, entry.number, entry.page] }
    assert_equal ['02-microkernels.html', 'a-glossary.html'], Erx::Book::Contents.neighbours(entries).fetch('16-storage.html')
    error = assert_raises(Erx::Error) do
      Erx::Book::Contents.derive(tree(OUTLINE), titles: titles.merge('chapter-9-processes' => '09-processes.html'), path: 'x')
    end
    assert_includes error.message, '09-processes.html'
  end

  # Seeded fault: handle only html_block, so the inline tag passes.
  def test_raw_html_is_refused_and_comments_dropped
    error = assert_raises(Erx::Error) { render("#{TITLE}<html_block sourcepos='3:1-3:5'>&lt;div&gt;x&lt;/div&gt;</html_block>") }
    assert_includes error.message, 'docs/book/16-storage.md:3: raw HTML is not allowed: <div'
    inline = "<paragraph sourcepos='5:1-5:9'>#{text('a')}<html_inline sourcepos='5:2-5:7'>&lt;span&gt;</html_inline></paragraph>"
    assert_includes assert_raises(Erx::Error) { render(TITLE + inline) }.message, ':5: raw HTML is not allowed: <span'
    page = render("#{TITLE}<html_block sourcepos='3:1-3:5'>&lt;!-- a note --&gt;</html_block>")
    refute_includes page.body.to_s, 'note'
  end

  # Seeded fault: let the comment rule drop comments before the draft check.
  def test_drafts_refused_or_shown
    marker = "#{TITLE}<html_block sourcepos='4:1-4:5'>&lt;!-- check: x --&gt;</html_block>"
    assert_includes assert_raises(Erx::Error) { render(marker) }.message, ':4: draft marker <!-- check:'
    assert_includes render(marker, drafts: true).body.to_s, '<p class="draft">&lt;!-- check: x --&gt;</p>'
  end

  # Seeded fault: match the caption against the preceding paragraph.
  def test_figures_take_the_caption_that_follows
    caption = "<paragraph sourcepos='9:1-9:9'><emph>#{text('Figure 16.2. The medium.')}</emph></paragraph>"
    page = render("#{TITLE}<code_block info='text' sourcepos='5:1-8:3'>a &lt; b</code_block>#{caption}" \
                  "<code_block info='mermaid' sourcepos='10:1-12:3'>flowchart LR</code_block>" \
                  "<paragraph sourcepos='14:1-14:9'><image destination='../../site/kiosk.png'>#{text('kiosk')}</image></paragraph>" \
                  "<paragraph sourcepos='15:1-15:9'><emph>#{text('Figure 16.3. Kiosk.')}</emph></paragraph>")
    html = page.body.to_s
    assert_includes html, '<figure id="figure-16-2"><pre class="code"><code>a &lt; b</code></pre><figcaption><span class="label">Figure 16.2.</span>The medium.</figcaption></figure>'
    assert_includes html, '<pre class="diagram-source"><code>flowchart LR</code></pre><figure id="figure-16-3">'
    assert_includes html, '<figure id="figure-16-3"><p class="image"><img src="media/abababababababab-kiosk.png" alt="kiosk"></p>'
  end

  # Seeded faults: drop the escape in attribute values; write non-ASCII characters as they are.
  def test_escaping_and_ascii
    body = "#{TITLE}<paragraph sourcepos='3:1-3:9'>#{text('pid <4.0.0> and ’quote’ ')}<code>a &amp;&amp; b</code>" \
           "<link destination='https://example.org/a#x&quot;onmouseover'>#{text('x')}</link></paragraph>"
    assert_includes assert_raises(Erx::Error) { render(body) }.message, 'not a well-formed URL'
    html = render(body.sub('#x&quot;onmouseover', '?q=a&amp;b')).body.to_s
    assert_includes html, 'pid &lt;4.0.0&gt; and &#x2019;quote&#x2019; <code>a &amp;&amp; b</code>'
    assert_includes html, 'href="https://example.org/a?q=a&amp;b"'
    assert html.ascii_only?
    assert_equal '<p title="&quot;&gt;&lt;script&gt;"></p>', Erx::Book::Html.tag('p', { title: '"><script>' }).to_s
    assert_raises(Erx::Error) { Erx::Book::Html.tag('a', { href: 'javascript:x' }) }
  end

  def test_section_numbers_follow_the_heading_tree
    page = render("#{TITLE}<heading level='2' sourcepos='3:1-3:9'>#{text('16.1 One')}</heading>" \
                  "<heading level='3' sourcepos='4:1-4:9'>#{text('16.1.1 Sub')}</heading>" \
                  "<heading level='2' sourcepos='5:1-5:9'>#{text('Summary')}</heading>")
    assert_equal [%w[161-one 16.1 One], ['summary', nil, 'Summary']], page.sections
    assert_includes page.body.to_s, '<h3 id="1611-sub"><span class="num">16.1.1</span>Sub</h3>'
    error = assert_raises(Erx::Error) { render("#{TITLE}<heading level='2' sourcepos='3:1-3:9'>#{text('16.2 Two')}</heading>") }
    assert_includes error.message, ':3: heading numbered 16.2, but the heading tree gives 16.1'
  end

  # Seeded fault: end an Erlang string at the first quote after a backslash.
  def test_code_highlights_comments_and_strings
    erlang = Erx::Book::Code.highlight('erlang', %(X = "50% \\"off\\"", % note\n)).to_s
    assert_equal 'X = <span class="st">&quot;50% \\&quot;off\\&quot;&quot;</span>, <span class="co">% note</span>' + "\n", erlang
    assert_includes Erx::Book::Code.highlight('c', "a; /* b */ s = \"x\";").to_s, '<span class="co">/* b */</span>'
    assert_includes Erx::Book::Code.highlight('sh', "echo '#x' # y").to_s, "<span class=\"st\">&#39;#x&#39;</span> <span class=\"co\"># y</span>"
    assert_includes Erx::Book::Code.highlight('ruby', 'p "#{a}" # c').to_s, '<span class="co"># c</span>'
  end

  # Seeded fault: check only link elements.
  def test_site_refuses_loads_from_another_host
    assert_raises(Erx::Error) { Erx::Site.remote_load('a.html', '<link rel="stylesheet" href="https://fonts.googleapis.com/css2">') }
    assert_raises(Erx::Error) { Erx::Site.remote_load('a.css', '@import url(https://x/y.css);') }
    assert_raises(Erx::Error) { Erx::Site.remote_load('a.html', '<img src="//x/y.png">') }
    assert_nil Erx::Site.remote_load('a.html', '<a href="https://example.org/">x</a><link rel="stylesheet" href="fonts.css">')
  end

  # Seeded fault: keep the special case for / only.
  def test_directory_routes
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'book'))
      %w[index.html book/index.html book/02-microkernels.html].each { |path| File.write(File.join(dir, path), path) }
      table = Erx::Site.routes(dir)
      assert_equal File.join(dir, 'book/index.html'), table.fetch('/book/')
      assert_equal File.join(dir, 'index.html'), table.fetch('/')
    end
  end
end
