# Painting and retouching

This chapter covers the tools that put color on a layer or change the pixels already there: the color wells, the Brush and Eraser, fills and gradients, and the retouching tools from Clone Stamp to Liquify.

All of these tools work on pixel layers. If the active layer is a text layer, shape, fill layer or smart object, rasterize it first with **Layer › Rasterize Layer**. The Brush and Eraser can also paint a layer mask (see [Painting a layer mask](#painting-a-layer-mask)).

When there is a selection, painting, filling and retouching stay inside it.

## Colors

### Foreground and background

The two overlapping color wells sit at the bottom of the tool palette. The front well is the foreground color, the one behind it is the background color.

- The Brush, Paint Bucket and the fill commands paint with the foreground color.
- The Gradient tool runs from the foreground to the background color by default.
- The Pattern Stamp and pattern fills use both.

Click a well to open the macOS color picker. Each well has its own opacity, which you set with the opacity control in the color picker. A foreground color at 50 % opacity paints at half strength, on top of the brush's own Opacity setting.

| Action | Button | Key |
|---|---|---|
| Swap foreground and background (colors and opacities) | Arrows button below the wells | X |
| Reset to black foreground and white background, both at 100 % | Half-filled circle below the wells | D |

### Swatches

Click the swatch palette button below the wells to open **Swatches**.

- Click a swatch to make it the foreground color.
- ⌥-click a swatch to make it the background color.
- Click **+** next to **Saved** to save the current foreground color.
- Right-click a saved swatch and choose **Remove** to delete it.

The top grid holds 20 fixed colors. Saved swatches are kept in the app's preferences, so they are available in every document.

### Eyedropper (I)

Click the image to pick the foreground color. ⌥-click to pick the background color. You can keep the mouse button down and drag to sample as you move.

The Eyedropper samples the image as you see it, with all visible layers combined. Fully transparent pixels are ignored.

## Brush (B)

Drag on a pixel layer to paint with the foreground color. The options bar above the canvas shows these controls:

| Control | Range | Default | What it does |
|---|---|---|---|
| Presets | menu | | Built-in and saved brushes (see below). |
| Size | 1 to 2048 px | 30 px | Diameter of the brush tip. The slider is scaled so small sizes are easy to set. |
| Hardness | 0 to 100 % | 80 % | 0 % gives a soft, fading edge; 100 % a crisp edge. |
| Opacity | 0 to 100 % | 100 % | The most paint a single stroke can lay down. Overlapping within one stroke never goes past it. |
| Flow | 1 to 100 % | 100 % | Paint per dab. Low flow builds up gradually as you paint over the same spot within a stroke. |
| Dynamics | popover | | Tip shape and pen settings (see below). |
| Paint mask | toggle | off | Shown only when the active layer has a mask. Paints the mask instead of the pixels. |

A circle on the canvas shows the brush size at the current zoom. Very small brushes also show a crosshair.

### Keys

- **[** makes the brush 10 % smaller, **]** 10 % larger (from 1 to 2000 px).
- **⇧-click** draws a straight line from where your last stroke ended to the click. This works with the Brush and the Eraser.

### Brush presets

Open **Presets** in the options bar.

| Preset | Settings |
|---|---|
| Soft Round | 60 px, hardness 0 % |
| Hard Round | 20 px, hardness 100 % |
| Chalk | 40 px, hardness 60 %, flow 80 %, textured |
| Calligraphic | 30 px, hardness 95 %, roundness 25 %, angle 45° |
| Airbrush | 120 px, hardness 0 %, flow 8 %, spacing 5 % |
| Pencil | 2 px, hardness 100 %, spacing 5 % |

Choosing a preset replaces all brush settings, including the Dynamics.

To save your own brush:

1. Set up the brush the way you want it.
2. Choose **Presets › Save Current Brush…**.
3. Type a name and click **Save**, or press Return.

Your brushes appear in the Presets menu below the built-in ones. Saving under an existing name replaces that brush. To remove one, choose **Presets › Delete** and pick it. Saved brushes are kept in the app's preferences and are available in every document.

### Dynamics

Click **Dynamics** to open a popover with two sections.

**Tip**

| Control | Range | Default | What it does |
|---|---|---|---|
| Spacing | 1 to 200 % | 10 % | Distance between dabs, as a share of the brush diameter. High values give a dotted line. |
| Roundness | 5 to 100 % | 100 % | Flattens the tip into an ellipse. |
| Angle | −180° to 180° | 0° | Turns a flattened tip. |
| Scatter | 0 to 100 % | 0 % | Moves each dab a random distance from the stroke. |
| Size Jitter | 0 to 100 % | 0 % | Makes each dab a random amount smaller. |
| Textured | toggle | off | Gives the tip a grainy texture. |

**Pen**

These settings only matter with a pen tablet. With a mouse, pressure is always full and there is no tilt or rotation.

| Toggle | Default | What it does |
|---|---|---|
| Pressure → Size | on | Light pressure paints a thinner line (down to 15 % of the size). |
| Pressure → Flow | off | Light pressure lays down less paint (down to 10 % of the flow). |
| Tilt → Angle | off | The tip's long axis follows the direction the pen leans. |
| Tilt → Roundness | off | The tip flattens as you lean the pen over, like the side of a pencil. |
| Rotation → Angle | off | Turning the pen barrel turns the tip. Needs a pen that reports rotation. |

### Pen tablets

Glimmer reads pressure, tilt and barrel rotation from a pen tablet. Two settings in **Settings › Tablet** apply to every tool that uses pressure (see [Settings](14-settings.md)):

- **Pen Pressure** sets the pressure curve with a slider from Soft to Firm. Soft reaches full size and flow with a lighter touch; Firm needs more force. The graph shows the curve. **Reset** returns it to a straight line.
- **Use pen tilt** turns tilt on or off for all brushes. It is on by default. Tilt only changes a stroke when Tilt → Angle or Tilt → Roundness is on in Dynamics.

Glimmer corrects tilt for a rotated canvas view, so the tip leans the way the pen does on screen.

### Painting a layer mask

To paint a mask, either click the mask thumbnail in the Layers panel or turn on **Paint mask** in the options bar. **Editing mask** then appears next to the document name and size at the top left of the window.

On a mask, the Brush paints with the brightness of the foreground color and the Eraser paints with the brightness of the background color. With the default colors (press D), the Brush paints black, which hides the layer, and the Eraser paints white, which shows it again. Press X to swap the two. Gray values give partial transparency. For more on masks, see [Layer masks](04-layers.md#layer-masks).

To go back to painting pixels, click the layer thumbnail or turn off **Paint mask**.

## Eraser (E)

The Eraser has the same options as the Brush: presets, Size, Hardness, Opacity, Flow and Dynamics. Brush and Eraser share one set of settings, so changing the size of one changes the other.

On a pixel layer, the Eraser makes pixels transparent. Opacity and Flow control how much it removes. On a mask, it paints as described above.

## Paint Bucket (K)

Click a pixel to fill it and the area of similar color around it with the foreground color.

| Control | Range | Default | What it does |
|---|---|---|---|
| Tolerance | 0 to 255 | 32 | How different a pixel may be from the one you clicked and still be filled. Each channel, including alpha, is compared. 0 fills only that exact color. |
| Contiguous | toggle | on | On fills only connected pixels. Off fills every matching pixel in the image. |
| Sample all layers | toggle | on | On decides what to fill from the whole visible image. Off looks only at the active layer. |
| Opacity | 0 to 100 % | 100 % | Strength of the fill. This is the same Opacity setting the Brush uses. |
| Fill | menu | | Fills without tolerance (see below). |

The fill always goes into the active pixel layer, even when Sample all layers is on. With a selection, only the part of the region inside the selection is filled.

### The Fill menu

The **Fill** menu in the Paint Bucket options fills the whole selection, or the whole layer when nothing is selected, with no tolerance involved:

- **Selection with Foreground** (or **Whole Layer with Foreground**)
- **Selection with Pattern** (or **Whole Layer with Pattern**)
- **Pattern** picks the pattern for pattern fills: Checkerboard, Dots, Stripes, Grid or Noise.

## Fill commands

The Edit menu has three fill commands. Each fills the selection on the active pixel layer, or the whole layer when there is no selection.

| Command | Key |
|---|---|
| **Edit › Fill with Foreground Color** | ⌥⌫ |
| **Edit › Fill with Background Color** | ⌘⌫ |
| **Edit › Fill with Pattern** | |

The color fills use the color's opacity together with the Opacity setting from the Brush and Paint Bucket options. If a fill comes out weaker than you expect, check that Opacity is at 100 %.

**Fill with Pattern** paints the pattern chosen in the Paint Bucket's Fill menu or the Pattern Stamp options, at the Pattern Stamp's Scale, in the foreground and background colors.

To get a fill you can change later, use a fill layer from **Layer › New Fill Layer** instead.

## Gradient (G)

Drag across the canvas to draw a gradient. The gradient does not change any pixels. It becomes a new Gradient fill layer above the active layer. If there is a selection, the new layer gets a mask in the shape of the selection.

Hold ⇧ while dragging to keep the direction to steps of 45°. A very short drag (under 2 px) does nothing.

| Control | What it does |
|---|---|
| Linear / Radial | The gradient type. Linear runs along the drag. Radial spreads out in a circle from where you start the drag; the length of the drag sets the radius. |
| Colors menu | **Foreground to Background**, **Foreground to Transparent**, or one of the ready-made gradients: **Black to White**, **Sunset**, **Ocean**, **Spectrum**. The menu shows **Custom** after you edit the stops. |
| Edit Stops | Opens the stops editor. |
| Reverse | Swaps the ends of the gradient. |

### Stops and opacity

**Edit Stops** opens a popover with a preview bar and one row per stop. In each row you can:

- click the color well to change the stop's color,
- drag the slider to move the stop along the gradient,
- click the minus button to remove the stop. A gradient keeps at least two stops.

**Add Stop** adds a stop in the middle, with the color the gradient already has there.

With Foreground to Background, each end takes its opacity from the color well, so a foreground at 50 % opacity starts the gradient half transparent. Foreground to Transparent fades the foreground color to nothing. To make the whole gradient fainter, lower the opacity of the gradient layer in the Layers panel.

### Changing a gradient later

Select the Gradient layer to edit it in the properties at the top of the Layers panel: style, stops, angle and Reverse. The stops editor there works the same way as the one in the options bar.

## Clone Stamp (S)

The Clone Stamp copies pixels from one part of the layer to another.

1. ⌥-click the spot you want to copy from. This sets the source.
2. Paint over the spot you want to cover.

While you hold ⌥, the brush circle turns into a target marker, so you can see exactly where the source will be. After the source is set, a small circle with a crosshair shows where Glimmer is copying from as you move and paint.

| Control | Range | Default | What it does |
|---|---|---|---|
| Size | 1 to 2048 px | 30 px | Shared with the Brush. |
| Hardness | 0 to 100 % | 80 % | Shared with the Brush. |
| Opacity | 0 to 100 % | 100 % | Shared with the Brush. |
| Aligned | toggle | on | On keeps the same distance between source and brush for every stroke. Off starts each new stroke again from the source point. |

⌥-click again at any time to set a new source. The Clone Stamp copies from the active layer only.

## Healing Brush (J)

The Healing Brush works like the Clone Stamp, with the same options and the same ⌥-click to set the source. The difference is in how the copy is blended: it keeps the texture of the source but takes on the color and brightness around the spot you paint. This makes it good for blemishes, dust and small marks, where a plain clone would leave a patch of the wrong tone.

Larger brush sizes blend over a wider area.

## Pattern Stamp

Pick the Pattern Stamp in the tool palette (it has no key). It paints a pattern in the foreground and background colors.

| Control | Range | Default |
|---|---|---|
| Size | 1 to 2048 px | 30 px |
| Hardness | 0 to 100 % | 80 % |
| Opacity | 0 to 100 % | 100 % |
| Pattern | Checkerboard, Dots, Stripes, Grid, Noise | Checkerboard |
| Scale | 4 to 256 px | 32 px |

The pattern is fixed to the canvas, so strokes that overlap line up with each other.

## Dodge and Burn (O, ⇧O)

Dodge lightens the pixels you paint over. Burn darkens them. Press O for Dodge and ⇧O for Burn.

| Control | Range | Default | What it does |
|---|---|---|---|
| Size | 1 to 2048 px | 30 px | Shared with the Brush. |
| Hardness | 0 to 100 % | 80 % | Shared with the Brush. |
| Range | Shadows, Midtones, Highlights | Midtones | Which tones the tool affects most. |
| Exposure | 1 to 100 % | 50 % | Strength of the effect. |

Start with a low Exposure and build up the effect with several strokes.

## Blur, Sharpen and Smudge

Pick these in the tool palette. They have no keys. Each has Size, Hardness and a **Strength** slider (1 to 100 %, default 50 %).

- **Blur** softens the pixels under the brush. Higher Strength blurs more.
- **Sharpen** increases local contrast under the brush. High Strength can add visible halos, so build it up with light strokes.
- **Smudge** drags color along the direction of the stroke, like a finger through wet paint. Strength sets how far the color is carried.

## Liquify

Liquify pushes, pulls, shrinks and swells parts of the image. Choose **Filter › Liquify…** (⇧⌘X). The active layer must be a pixel layer with content.

While Liquify is running, the options bar shows its controls, and every drag on the canvas reshapes the layer until you apply or cancel.

| Control | Range | Default | What it does |
|---|---|---|---|
| Mode | menu | Forward Warp | What a drag does (see below). |
| Size | 8 to 2048 px | 150 px | Diameter of the Liquify brush, shown as a circle on the canvas. |
| Pressure | 1 to 100 % | 50 % | Strength of each dab. Pen pressure scales it further. |
| Restore All | button | | Undoes every Liquify change made in this session. |
| Cancel | button | | Leaves Liquify without changing the layer. |
| Apply | button | | Applies the changes to the layer. |

The modes:

- **Forward Warp** pushes pixels in the direction you drag.
- **Reconstruct** paints back toward the original, undoing warps where you brush.
- **Pucker** pulls pixels toward the center of the brush, which shrinks what is under it.
- **Bloat** pushes pixels away from the center, which enlarges what is under it.
- **Twirl Clockwise** and **Twirl Counter-clockwise** spin pixels around the center of the brush.

Forward Warp only acts when you drag. The other modes also act where you first click.

Press Return to apply or Esc to cancel. Applying is one undo step.

If there is a selection when you start, only the selected part of the layer changes. Pixels outside the selection stay where they are.
