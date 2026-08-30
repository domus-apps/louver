import AppKit

/* NSApplication subclass with one job: keep the status menu open when a
   slider drag ends outside it.

   A menu dismisses on any mouse-up outside its bounds — that's menu
   semantics, and the system's own Sound control avoids it only by not
   being a menu at all (it's a Control Center panel). Louver's sliders
   live in a real NSMenu, so while one is being dragged, the single
   dangerous event — the final left mouse-up — is rerouted here at the
   sendEvent chokepoint: its location is clamped into the slider's frame
   before dispatch. The slider's gesture ends normally (same value: an
   x beyond the track's ends already means 0 or 1), and the menu sees an
   inside mouse-up, which doesn't dismiss it. */
final class LouverApplication: NSApplication {
    /* The slider strip being dragged right now; set from the row's
       onDraggingChanged. Main thread only, like all of AppKit. */
    static weak var sliderDragTarget: NSView?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp,
            let target = Self.sliderDragTarget,
            let window = target.window
        {
            let frameInWindow = target.convert(target.bounds, to: nil)
            /* The up may belong to another window (or none); re-anchor it
               to the slider's window via the current screen location. */
            var location =
                event.windowNumber == window.windowNumber
                ? event.locationInWindow
                : window.convertPoint(fromScreen: NSEvent.mouseLocation)
            location.x = min(max(location.x, frameInWindow.minX), frameInWindow.maxX)
            location.y = min(max(location.y, frameInWindow.minY), frameInWindow.maxY)

            if let relocated = NSEvent.mouseEvent(
                with: .leftMouseUp, location: location,
                modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: event.eventNumber, clickCount: event.clickCount,
                pressure: 0)
            {
                super.sendEvent(relocated)
                return
            }
        }
        super.sendEvent(event)
    }
}
