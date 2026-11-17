# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The generated reader of ui.txt's binary form that a native renderer links
# (docs/design-abi.md, "Widget format"). Seeds: a stream of an insert with a
# status text, a list and an enum, a set with removals, a move, a commit, a
# screen, each input form, a repaint and a presented; an insert of the
# additions of docs/design-desktop-programs.md: a graph's samples with gaps,
# a list's icons, a button's role, icon and current; an insert cut short; and
# a damage report, which a renderer refuses. Kinds, properties and members
# are numbered from abi/formats/ui.txt by name.
require_relative '../lib/erx/abi'

ui = Erx::ABI::Generator.plan(root: File.expand_path('../..', __dir__)).schema.ui
kind = ->(name) { ui.kinds.find { |entry| entry.name == name }.number }
property = ->(name) { ui.properties.find { |entry| entry.name == name } }
prop = ->(name) { [property.call(name).number].pack('C') }
# A member's number in the enum of a property, or of its list's elements.
member = lambda do |name, atom|
  type = property.call(name).type
  type = type.element || type
  type.numbers.fetch(type.atoms.index(atom))
end
record = ->(body) { [body.bytesize].pack('V') + body }
text = ->(bytes) { [bytes.bytesize].pack('V') + bytes }
status_text = prop.call('text') + [0, 0, 0, 0].pack('CCCV') + text.call('hello')
list = prop.call('items') + [2].pack('v') + text.call('one') + text.call("tw\xc3\xb6".b)
insert = record.call([1, 5, 0, 0, kind.call('list'), 4].pack('CVVvCC') + prop.call('width') + [100].pack('V') +
                     prop.call('align') + [member.call('align', 'fill')].pack('C') + status_text + list)
set = record.call([3, 5, 1].pack('CVC') + prop.call('value') + [-7].pack('l<') +
                  [2].pack('C') + prop.call('text') + prop.call('width'))
samples = prop.call('samples') + [4].pack('v') + [0, Erx::ABI::UI::NONE, 2_147_483_647, 9].pack('l<4')
graph = record.call([1, 6, 5, 0, kind.call('graph'), 6].pack('CVVvCC') + prop.call('min') + [0].pack('l<') +
                    prop.call('max') + [2_147_483_647].pack('l<') + status_text + samples +
                    prop.call('mark') + [9].pack('l<') + prop.call('role') + [member.call('role', 'numeric')].pack('C'))
icons = prop.call('icons') + [2].pack('v') + [member.call('icons', 'folder'), member.call('icons', 'calendar')].pack('CC')
activated = record.call([1, 7, 5, 1, kind.call('list'), 2].pack('CVVvCC') + list + icons)
button = record.call([1, 8, 5, 2, kind.call('button'), 4].pack('CVVvCC') + status_text +
                     prop.call('role') + [member.call('role', 'title')].pack('C') +
                     prop.call('icon') + [member.call('icon', 'clock')].pack('C') + prop.call('current') + [1].pack('C'))
trend = record.call([1, 9, 5, 3, kind.call('label'), 2].pack('CVVvCC') + status_text +
                    prop.call('trend') + [member.call('trend', 'down')].pack('C'))
inputs = [[1, 10, 20, 1].pack('CvvC'), [2, 1, 30].pack('CCv') + [0x41].pack('V'), [3, 0xff].pack('CC')]
stream = insert + set + record.call([4, 5, 1].pack('CVv')) + record.call([5].pack('C')) +
         record.call([7, 640, 480, 0x68081828].pack('CvvV')) + inputs.map { |body| record.call([8].pack('C') + body) }.join +
         record.call([9].pack('C')) + record.call([11].pack('C'))

Erx::PackFuzz.declare_target(
  sources: ['build/gen/display/generated/erx_ui_wire.c'],
  seeds: {
    'stream' => stream,
    'additions' => graph + activated + button + trend,
    'insert-cut' => insert[0, insert.bytesize - 3],
    'damage' => record.call([10, 1, 1, 1, 0, 0, 1, 1].pack('CvvCvvvv'))
  }
)
