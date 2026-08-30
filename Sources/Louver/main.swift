import AppKit

/* sharedApplication instantiates the class it's messaged on — this is
   what makes LouverApplication (the slider-drag event reroute) the app. */
let app = LouverApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
/* Menu bar only — no Dock icon. The bundled build also sets LSUIElement,
   but this makes plain `swift run` behave the same way. */
app.setActivationPolicy(.accessory)
app.run()
