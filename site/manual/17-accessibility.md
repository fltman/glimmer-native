# Accessibility

Glimmer works with VoiceOver and with the keyboard alone. This chapter collects what helps when you use either.

## Using Glimmer without a mouse

Every command is in the menus and in the command palette (⌘K), so you can run all of them from the keyboard. Type part of a name in the palette, move with ↑ ↓ and press Return.

To move between controls with Tab, turn on **Keyboard navigation** under **System Settings › Keyboard** (or Full Keyboard Access under **Accessibility › Keyboard**). Then:

- **Tab** moves from the canvas to the panels and back. Without Full Keyboard Access, Tab on the canvas hides the interface instead, as in other image editors. **View › Hide Interface** does that either way.
- **/** on the canvas jumps to the search bar at the bottom of the window, or opens the command palette when the bar is hidden.
- **The tool palette, panels and inspectors** are ordinary buttons, sliders and menus. Space activates the focused control.
- **The Layers panel:** ↑ ↓ select a layer, Return renames it. **Layer › Layer Mask › Edit Layer Mask** (⌘\\) switches between painting the layer and its mask, which you would otherwise pick by clicking a thumbnail.
- **Curves:** click the curve or Tab to it. The arrow keys move the marked point by one level (⇧ by ten), and ⌥← ⌥→ mark another point.
- **Swatches** are buttons named by their color. Space sets the foreground color.
- **Dialogs** (New Document, Export, Layer Style, Batch Process, filters) take Return for their main button and Esc to cancel. The Welcome and Agent Access windows close with Esc.

The single-letter tool keys work when the canvas has the keyboard. The full list is in [Keyboard shortcuts](15-keyboard-shortcuts.md).

## VoiceOver

- **Tools** are read by name, and the selected tool is announced as selected. Their help tags give the key for each.
- **The canvas** is one element, "Canvas". Its value gives the size, the number of layers, the zoom, the active layer, whether there is a selection and the current tool.
- **Layers** are read as one item each: the name, then blend mode, opacity and whether the layer is hidden, has a mask, is clipped or has a layer style. The selected layer is announced as selected. VoiceOver's actions on a layer (VO-Command-Space) are **Hide** or **Show**, **Rename**, **Select**, **Edit Mask** and **Edit Layer**.
- **Sliders** are read with their name and current value, for example "Opacity, 75 %". The Curves graph reads its points as input → output pairs and can be adjusted with VO-Up and VO-Down; its actions mark the next or previous point.
- **The assistant** reads each message with who wrote it ("You:" or "Assistant:"). Each plan step is read with its status (Waiting, Running, Done, Failed or Skipped). **AUTO-EDIT** is read as a switch that is on or off.
- **Announcements:** Glimmer says "Copied" when you copy the text for your agent, reads the result of **Test Key** in Settings, and reads short notices such as "Saved photo.png for Flimmer".
- **Settings:** each **Remove** button under Models names its model, and the pen pressure slider says how soft or firm the response is.

Decorative icons, such as the sparkles beside titles and the color dots in the Channels panel, are hidden from VoiceOver.

## Errors, warnings and notices

Glimmer tells them apart by their sign and by a word, not by color alone. That holds in Light and Dark mode and for anyone who cannot tell red from green.

| Sign | Means | The text says |
|---|---|---|
| An octagon with a cross | An error: something could not be done | What could not be done |
| A triangle with an exclamation mark | A warning | What follows from it, so you can act |
| An *i* in a circle | A notice | Something worth knowing |
| A check in a circle | Done | What was done |
| A spinning indicator | Work under way | What is being done |

Each sign means one thing in the whole app. The color sits on the sign; the text beside it stays in the ordinary text color, so it reads at full contrast. VoiceOver says the kind first, as in "Error: …" or "Warning: …".

## Contrast and text size

- Text in the dark editing window meets the WCAG contrast level for normal text (at least 4.5 : 1). Buttons filled with Glimmer's indigo use a deeper shade so white text on them stays readable, and the outline of the assistant's text field stands out from the panel.
- The Welcome window, Settings and dialogs use the system's colors and follow Light or Dark mode.
- The signs for errors, warnings, notices and done stand out from every surface they are shown on by at least 3 : 1, and by at least 4.5 : 1 in the editing window and on light surfaces.
- Glimmer's text uses the system text styles, and buttons and chips grow with their text rather than cutting it off.

## If something can't be reached

If a control can't be reached with the keyboard or isn't read by VoiceOver, please report it on the project's issue page on GitHub, with the window and panel where it happens.
