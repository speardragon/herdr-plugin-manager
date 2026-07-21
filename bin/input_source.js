// macOS input-source helper (osascript JXA, zero dependencies).
//
//   osascript -l JavaScript input_source.js current       → print current source id
//   osascript -l JavaScript input_source.js switch-ascii  → if the current source is
//       not ASCII-capable (e.g. Korean IME), switch to the last-used ASCII layout
//       and print the previous source id; prints nothing when no switch was needed
//   osascript -l JavaScript input_source.js select <id>   → select a source by id
//
// Uses the same Text Input Source API herdr's switch_ascii_input_source_in_prefix
// option is built on. TISCreateInputSourceList/TISSelectInputSource are re-bound
// with 'id' signatures — JXA's default CFRef bridging rejects them with
// "Ref has incompatible type (-2700)" otherwise.
ObjC.import('Carbon')
ObjC.bindFunction('TISCreateInputSourceList', ['id', ['id', 'B']])
ObjC.bindFunction('TISSelectInputSource', ['int', ['id']])

function sourceId(src) {
  return ObjC.castRefToObject($.TISGetInputSourceProperty(src, $.kTISPropertyInputSourceID)).js
}

function isAsciiCapable(src) {
  return !!ObjC.castRefToObject($.TISGetInputSourceProperty(src, $.kTISPropertyInputSourceIsASCIICapable)).js
}

function run(argv) {
  const cmd = argv[0] || 'current'
  const cur = $.TISCopyCurrentKeyboardInputSource()

  if (cmd === 'current') return sourceId(cur)

  if (cmd === 'switch-ascii') {
    if (isAsciiCapable(cur)) return ''
    const prev = sourceId(cur)
    const ascii = $.TISCopyCurrentASCIICapableKeyboardInputSource()
    $.TISSelectInputSource(ObjC.castRefToObject(ascii))
    return prev
  }

  if (cmd === 'select') {
    const id = argv[1]
    if (!id) return 'missing id'
    const list = $.TISCreateInputSourceList($({ TISPropertyInputSourceID: id }), false)
    if (list.count > 0) {
      $.TISSelectInputSource(list.objectAtIndex(0))
      return 'ok'
    }
    return 'not-found'
  }

  return 'usage: current | switch-ascii | select <id>'
}
