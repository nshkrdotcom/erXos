# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'html'

module Erx
  module Book
    # The page around each rendered body (docs/design-book-site.md, "Typography
    # and look"): a running header with the chapter's number and title, the
    # contents rail (a <details> list on narrow screens), the body, and the
    # previous and next pages. No script: the page is complete HTML.
    class Layout
      attr_reader :stylesheet, :drafts

      # stylesheet: the book stylesheet's published name; names: fonts_css and
      # tokens_css, the shared stylesheets' names; entries: the contents;
      # results: each page's file name and its Page::Result.
      def initialize(stylesheet:, names:, entries:, results:, drafts:)
        @stylesheet = stylesheet
        @names = names
        @entries = entries
        @results = results
        @drafts = drafts
        @neighbours = Contents.neighbours(entries)
      end

      # Each page's file name and its whole HTML, the contents page included.
      def pages
        @results.to_h { |name, result| [name, page(name, result).to_s] }
                .merge('index.html' => contents_page.to_s)
      end

      private

      def page(name, result)
        heading = [result.label, result.title].compact.join('. ')
        previous, following = @neighbours.fetch(name, [nil, nil])
        shell(title: heading, running: running(result), current: name,
              body: Html.join(Html.tag('article', { class: "page #{File.basename(name, '.html')}" }, result.body),
                              pager(previous, following)))
      end

      def running(result)
        Html.join(Html.tag('span', { class: 'running-label' }, result.label || 'erXos'),
                  Html.tag('span', { class: 'running-title' }, result.title))
      end

      def contents_page
        parts = @entries.chunk_while { |a, b| a.part == b.part }.map do |group|
          Html.tag('section', { class: 'toc-part' },
                   Html.tag('h2', {}, group.first.part),
                   Html.tag('ol', { class: 'toc' }, group.map { |entry| toc_entry(entry) }))
        end
        shell(title: 'Contents', running: Html.join(Html.tag('span', { class: 'running-label' }, 'erXos'),
                                                    Html.tag('span', { class: 'running-title' }, 'Contents')),
              current: 'index.html',
              body: Html.tag('article', { class: 'page contents' },
                             Html.tag('h1', {}, Html.tag('span', { class: 'title' }, TITLE)),
                             Html.tag('p', { class: 'outline-link' }, Html.tag('a', { href: Address.local('outline.html') }, 'About this book: the outline')),
                             *parts))
      end

      def toc_entry(entry)
        title = Html.tag('span', { class: 'toc-title' }, entry.title)
        number = Html.tag('span', { class: 'toc-number' }, entry.number.to_s)
        leader = Html.tag('span', { class: 'toc-leader' })
        unless entry.page
          return Html.tag('li', { class: 'unwritten' }, number, title, leader, Html.tag('span', { class: 'toc-note' }, 'in preparation'))
        end

        Html.tag('li', {}, Html.tag('a', { href: Address.local(entry.page) }, number, title, leader))
      end

      # The contents as the rail lists them: every written chapter, the
      # current one opened to its sections.
      def rail(current)
        items = @entries.filter_map do |entry|
          next unless entry.page

          link = Html.tag('a', { href: Address.local(entry.page), 'aria-current': (entry.page == current ? 'page' : nil) },
                          Html.tag('span', { class: 'toc-number' }, entry.number.to_s), Html.tag('span', { class: 'toc-title' }, entry.title))
          Html.tag('li', {}, link, (sections(@results.fetch(entry.page)) if entry.page == current))
        end
        Html.tag('ol', { class: 'rail-list' }, items)
      end

      def sections(result)
        return nil if result.sections.empty?

        Html.tag('ol', { class: 'rail-sections' }, result.sections.map do |id, number, text|
          Html.tag('li', {}, Html.tag('a', { href: Address.fragment(id) },
                                      Html.tag('span', { class: 'toc-number' }, number.to_s), Html.tag('span', { class: 'toc-title' }, text)))
        end)
      end

      def pager(previous, following)
        link = ->(name, rel, label) { name && Html.tag('a', { href: Address.local(name), rel:, class: rel }, Html.tag('span', { class: 'pager-label' }, label), page_title(name)) }
        Html.tag('nav', { class: 'pager', 'aria-label': 'Previous and next' }, link.(previous, 'prev', 'Previous'), link.(following, 'next', 'Next'))
      end

      def page_title(name)
        result = @results.fetch(name)
        Html.tag('span', { class: 'pager-title' }, [result.label, result.title].compact.join('. '))
      end

      def shell(title:, running:, current:, body:)
        rail = rail(current)
        Html.document(Html.tag('html', { lang: 'en' },
                               Html.tag('head', {},
                                        Html.tag('meta', { charset: 'utf-8' }),
                                        Html.tag('meta', { name: 'viewport', content: 'width=device-width, initial-scale=1' }),
                                        Html.tag('title', {}, "#{title} | erXos"),
                                        Html.tag('link', { rel: 'stylesheet', href: Address.local("../#{@names.fetch(:fonts_css)}") }),
                                        Html.tag('link', { rel: 'stylesheet', href: Address.local("../#{@names.fetch(:tokens_css)}") }),
                                        Html.tag('link', { rel: 'stylesheet', href: Address.local(@stylesheet) }),
                                        Html.tag('link', { rel: 'icon', href: Address.local('../favicon.svg'), type: 'image/svg+xml' })),
                               Html.tag('body', { class: 'book' },
                                        Html.tag('header', { class: 'running' },
                                                 Html.tag('a', { class: 'running-book', href: Address.local('index.html') }, TITLE),
                                                 Html.tag('span', { class: 'running-chapter' }, running)),
                                        Html.tag('details', { class: 'toc-narrow' }, Html.tag('summary', {}, 'Contents'), rail),
                                        Html.tag('div', { class: 'frame' },
                                                 Html.tag('nav', { class: 'rail', 'aria-label': 'Contents' }, rail),
                                                 Html.tag('main', {}, body)))))
      end
    end
  end
end
