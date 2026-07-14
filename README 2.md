# DX Trader — Welcome Walkthrough (Xcode drop-in)

1. Drag WelcomeWalkthrough.swift into your Xcode project.
2. Drag the 7 JPGs from images/ into Assets.xcassets. Name each image set
   exactly like its filename (wt-home, wt-intents, wt-solutions, wt-menu,
   wt-package, wt-ecb-queue, wt-ecb-ledger).
3. Present it from your root view:

   @AppStorage("hasOnboarded") private var hasOnboarded = false

   var body: some View {
       MainView()
           .fullScreenCover(isPresented: .constant(!hasOnboarded)) {
               WelcomeWalkthrough { hasOnboarded = true }
           }
   }

4. Optional: add a "Replay tour" row in Settings that sets hasOnboarded = false.

Notes
- These JPGs are the name-covered 640px versions from the mockup. For Retina
  crispness, re-export the same screens from your device at full resolution and
  drop them in with the same names — the callout dots are percentage-anchored,
  so they'll stay in place.
- Callout coordinates, copy, and colors match "Welcome Walkthrough.dc.html" in
  this project — edit copy there first if you want to preview changes, then
  mirror them in the Swift file.
- The consent card gates on all three checkboxes, then calls onFinish().
