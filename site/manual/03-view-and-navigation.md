# View and Navigation

This chapter explains how you move around the image: zooming, panning, rotating the view, and the aids that help you place things precisely. None of the view commands change your image.

## Zoom

The title chip in the top-left corner shows the current zoom. At 100 %, one pixel of the image fills one pixel of your display. Glimmer zooms from 2 % to 6400 %.

| Command | Shortcut | What it does |
| --- | --- | --- |
| **View › Zoom In** | ⌘+ (or ⌘=) | Goes to the next zoom step. |
| **View › Zoom Out** | ⌘- | Goes to the previous zoom step. |
| **View › Fit on Screen** | ⌘0 | Shows the whole image in the window. |
| **View › Actual Pixels (100%)** | ⌘1 | Shows the image at 100 %. |

Zoom In and Zoom Out step through fixed levels: 2, 3, 4, 5, 6.25, 8.33, 12.5, 16.7, 25, 33.3, 50, 66.7, 100, 150, 200, 300, 400, 600, 800, 1200, 1600, 2400, 3200, 4800 and 6400 %. They zoom around the center of the window.

A new or opened image is fitted to the window. When you resize the window, the image stays centered. After a crop, Glimmer keeps the zoom you had.

### Zooming with the mouse or trackpad

- **Pinch** on the trackpad to zoom around the pointer.
- Hold **⌥** or **⌘** and scroll with two fingers to zoom around the pointer.
- With a mouse, turn the **scroll wheel** to zoom around the pointer.
- **Double-tap with two fingers** (smart zoom) to switch between Fit on Screen and 100 %.

## Pan

- **Scroll with two fingers** on the trackpad to move the image.
- Choose the **Hand** tool (H) and drag.
- Hold **Space** and drag with any tool. Release Space to go back to your tool.
- Drag with the **middle mouse button**.

## Rotating the view

You can turn the canvas to draw or retouch at a comfortable angle. This only turns your view. The image itself is not rotated. To rotate the image, use the commands in the **Image** menu instead.

- **Rotate with two fingers** on the trackpad. The view snaps to 0°, 90°, 180° and 270° when you come within 3° of them.
- **View › Rotate View Left 15°** and **View › Rotate View Right 15°** turn the view in 15° steps.
- **View › Reset View Rotation** sets the view straight again.

The Navigator also has rotation controls (see below).

## Navigator

Choose **View › Navigator** (⌥⌘N). The Navigator appears in the bottom-right corner of the window.

- The thumbnail shows the whole image. A red frame marks the part you see in the window. Click or drag in the thumbnail to move the view there.
- The magnifier buttons and the slider zoom around the center of the window. The current zoom is shown next to them.
- The rotation buttons turn the view 15° left or right. You can also type an angle between −360° and 360° in the field. **Reset** sets the view straight.

The thumbnail updates shortly after you stop editing. Choose **View › Navigator** again to hide it.

## Rulers

Choose **View › Rulers** (⌘R) to show pixel rulers along the top and left edges of the canvas. The rulers follow the zoom and position of the image.

## Guides

Guides are thin cyan lines that help you line things up. They are not part of the image and are never exported.

- **Add a guide:** show the rulers, then drag from the top ruler for a horizontal guide or from the left ruler for a vertical guide. Release where you want it.
- **Move a guide:** drag it with any tool except the Hand tool. You don't need to switch to the Move tool. Guides land on whole pixels.
- **Delete a guide:** drag it off the image, or back onto a ruler.
- **Delete all guides:** choose **View › Clear Guides**.

While snapping is on, a guide you drag snaps to the image edges and center, to other guides and to the grid.

Adding, moving and deleting guides are undo steps. Guides are saved in the document.

## Grid

Choose **View › Grid** (⌘') to show a grid over the image. It has a line every 100 pixels, and each square is divided into four by fainter lines. Projects imported from Glimmer for the web keep their own grid size.

When you zoom out so far that the lines would crowd together, Glimmer hides them. The fainter lines disappear first.

## Snap

Choose **View › Snap** (⇧⌘;) to turn snapping on or off. Snapping is on in new documents.

With snapping on, these things snap when they come within a few screen pixels of a snap line:

- layers you drag with the Move tool (their edges or their center);
- marquee selections;
- the crop frame;
- points you place with the Pen tool;
- shapes;
- guides.

The snap lines are the edges and the center of the image, your guides, and, when the grid is visible, the grid lines including the fainter ones.

The rulers, grid, guides and snap setting belong to each document and are saved with it. Turning them on or off is an undo step.

## Hide Interface

Press **Tab** (or choose **View › Hide Interface**) to hide everything except the image: the tool palette, title chip, options bar, chrome bar, side panel, Navigator, omnibar and selection bar. Press Tab again to bring them back.

Tab works when the canvas has the keyboard. While you type in a text layer or a text field, Tab goes to the text instead.

## Classic Layout

Choose **View › Classic Layout** to dock the side panel to the right edge of the window, at full height, with all its tabs. The image is fitted to the narrower canvas. Choose the command again to go back to the floating panels. See [Getting Started](01-getting-started.md#classic-layout) for details.

## Showing panels

| Command | Shortcut | What it does |
| --- | --- | --- |
| **View › Show/Hide Layers** | ⌥⌘L | Shows or hides the side panel. |
| **View › Command Palette…** | ⌘K | Opens the command palette. |

To open the side panel on a particular tab, type "Layers Panel", "Paths Panel", "Channels Panel" or "History Panel" in the command palette.
