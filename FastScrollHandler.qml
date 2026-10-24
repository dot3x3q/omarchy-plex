// Adapted from omarchy quickshell.spotify FastScrollHandler.qml (MIT).
//
// ALWAYS declare it with `parent: <the flickable>`. Declared bare inside a
// Flickable/ListView it becomes a child of contentItem, scrolls away with the
// content, and stops receiving the wheel after the first screen.
//
// Two orientations:
// - vertical (default): drives contentY. A wheel event that is clearly
//   sideways (Shift held, or a horizontal-dominant touchpad swipe) goes to
//   the horizontal list under the pointer instead, found by walking
//   contentItem.childAt(). It cannot simply be passed through: this handler
//   blocks, and with it rejected the nested list only ever saw Qt's native
//   slow wheel (verified offscreen: Shift+wheel moved a nested shelf 0 px).
// - horizontal: drives contentX. It takes sideways input always, and the
//   plain vertical wheel too when `verticalWheel` is true — right for a row
//   that is NOT inside a vertical scroller (the season picker), where the
//   vertical wheel otherwise does nothing at all. Shelves nested in a page
//   leave it false: hijacking the vertical wheel there would make a page
//   that is mostly shelves impossible to scroll.
import QtQuick

Item {
  id: root

  required property var flickable
  property bool horizontal: false
  property bool verticalWheel: false
  property real speedMultiplier: 4
  property real mouseWheelStep: Math.max(1,
    Number(Application.styleHints.wheelScrollLines) || 3) * 24

  signal scrolled()

  x: 0
  y: 0
  width: flickable.width
  height: flickable.height
  z: 1000

  function scrollDistance(pixelDeltaY, angleDeltaY) {
    var distance = Number(pixelDeltaY) || 0
    if (distance === 0)
      distance = (Number(angleDeltaY) || 0) / 120 * mouseWheelStep
    return distance * speedMultiplier
  }

  function boundedContentY(value) {
    var minimum = Number(flickable.originY) || 0
    var maximum = Math.max(minimum,
      minimum + Math.max(0, Number(flickable.contentHeight) || 0)
        - Math.max(0, Number(flickable.height) || 0))
    return Math.max(minimum, Math.min(maximum, value))
  }

  function boundedContentX(value) {
    var minimum = Number(flickable.originX) || 0
    var maximum = Math.max(minimum,
      minimum + Math.max(0, Number(flickable.contentWidth) || 0)
        - Math.max(0, Number(flickable.width) || 0))
    return Math.max(minimum, Math.min(maximum, value))
  }

  function scrollByDeltas(pixelDeltaY, angleDeltaY) {
    var distance = scrollDistance(pixelDeltaY, angleDeltaY)
    if (distance === 0 || !flickable.interactive) return flickable.contentY
    var previous = flickable.contentY
    flickable.cancelFlick()
    flickable.contentY = boundedContentY(flickable.contentY - distance)
    if (Math.abs(flickable.contentY - previous) > 0.01) scrolled()
    return flickable.contentY
  }

  function scrollXBy(distance) {
    if (distance === 0 || !flickable.interactive) return false
    var previous = flickable.contentX
    flickable.cancelFlick()
    flickable.contentX = boundedContentX(flickable.contentX - distance)
    var moved = Math.abs(flickable.contentX - previous) > 0.01
    if (moved) scrolled()
    return moved
  }

  // Deepest horizontal ListView under (x, y) of this handler's own frame.
  function horizontalListAt(x, y) {
    var host = flickable.contentItem
    var p = root.mapToItem(host, x, y)
    var found = null
    var depth = 0
    while (host && depth < 24) {
      var child = host.childAt(p.x, p.y)
      if (!child) break
      if (child !== flickable && child.orientation === ListView.Horizontal && child.contentWidth !== undefined) found = child
      p = host.mapToItem(child, p.x, p.y)
      host = child
      depth++
    }
    return found
  }

  // Shift+wheel is the desktop convention for "scroll sideways"; a touchpad
  // reports the swipe direction itself.
  function sideways(event) {
    var ax = Math.abs(Number(event.angleDelta.x) || 0) + Math.abs(Number(event.pixelDelta.x) || 0)
    var ay = Math.abs(Number(event.angleDelta.y) || 0) + Math.abs(Number(event.pixelDelta.y) || 0)
    return (event.modifiers & Qt.ShiftModifier) !== 0 || ax > ay
  }

  WheelHandler {
    id: wheelHandler
    target: null
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    blocking: true

    onWheel: function(event) {
      if (root.horizontal) {
        var side = root.sideways(event)
        if (!side && !root.verticalWheel) { event.accepted = false; return }
        // A sideways event carries its distance in x — except Shift+wheel,
        // which some platforms leave in y.
        var d = root.scrollDistance(event.pixelDelta.x, event.angleDelta.x)
        if (d === 0) d = root.scrollDistance(event.pixelDelta.y, event.angleDelta.y)
        event.accepted = root.scrollXBy(d)
        return
      }
      if (root.sideways(event)) {
        var list = root.horizontalListAt(wheelHandler.point.position.x, wheelHandler.point.position.y)
        if (!list || !list.interactive) { event.accepted = false; return }
        var dx = root.scrollDistance(event.pixelDelta.x, event.angleDelta.x)
        if (dx === 0) dx = root.scrollDistance(event.pixelDelta.y, event.angleDelta.y)
        var before = list.contentX
        list.cancelFlick()
        var minX = Number(list.originX) || 0
        var maxX = Math.max(minX, minX + list.contentWidth - list.width)
        list.contentX = Math.max(minX, Math.min(maxX, list.contentX - dx))
        event.accepted = Math.abs(list.contentX - before) > 0.01
        return
      }
      var distance = root.scrollDistance(event.pixelDelta.y, event.angleDelta.y)
      if (distance === 0 || !root.flickable.interactive) {
        event.accepted = false
        return
      }
      var previous = root.flickable.contentY
      var current = root.scrollByDeltas(event.pixelDelta.y, event.angleDelta.y)
      event.accepted = Math.abs(current - previous) > 0.01
    }
  }
}
