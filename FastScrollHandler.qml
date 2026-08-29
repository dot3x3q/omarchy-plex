// Adapted from omarchy quickshell.spotify FastScrollHandler.qml (MIT).
import QtQuick

Item {
  id: root

  required property var flickable
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

  function scrollByDeltas(pixelDeltaY, angleDeltaY) {
    var distance = scrollDistance(pixelDeltaY, angleDeltaY)
    if (distance === 0 || !flickable.interactive) return flickable.contentY
    var previous = flickable.contentY
    flickable.cancelFlick()
    flickable.contentY = boundedContentY(flickable.contentY - distance)
    if (Math.abs(flickable.contentY - previous) > 0.01) scrolled()
    return flickable.contentY
  }

  WheelHandler {
    target: null
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    blocking: true

    onWheel: function(event) {
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
