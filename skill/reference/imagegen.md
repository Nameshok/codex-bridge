# Image generation — what was measured, and what bites

> Notes behind the image routes. Everything here was measured against a real
> Codex CLI; where a number is quoted it came from a run, not from documentation.
> Which model and effort to use is decided by the route table, not by this file.

## Effort does not change the render

The picture is drawn by a separate image model. The agent only composes the
prompt for it. Effort therefore buys you a better reading of the brief, a more
precise prompt and a stricter check of the result — not a better renderer.

That still matters, because **each run writes its OWN final prompt** for the
image model. Two runs from the same brief produce different pictures because the
orchestrator differs, even though neither of them renders anything.

A 16-run matrix (three models across every effort, one brief) showed:

- On a thumbnail grid the variants look interchangeable. **Judge similarity and
  quality only at full size, on 1:1 crops.** On thumbnails the difference is
  invisible and the choice becomes random.
- Wall-clock time (160-500 s) shows no systematic dependence on model or effort.
  It is render-queue noise. This is why every image route is background-only.
- The highest effort did not improve the render, but it did behave like an art
  director: it picked up the previous version as an edit target on its own,
  found a brief violation, and ordered a targeted fix. Useful for the final
  polish of a showcase asset; wasteful for routine work.

## Resolution ceiling

For 16:9 the ceiling is about 1672x941, and it belongs to the image model, not to
the CLI. Requests for 3840x2160 and 2560x1440 both came back as 1672x941. The 4K
sizes in the documentation apply to the paid CLI path only.

Recipe for large assets (wallpapers, banners):

1. Demand **maximum micro-detail** in the brief — dense texture survives
   upscaling far better than smooth gradients.
2. Forbid the agent to resize anything; take the native file.
3. Upscale locally: Lanczos + unsharp mask (radius ~1.4, amount ~90%) plus
   luminance grain (sigma ~2.5). The grain masks interpolation mush and banding
   in dark areas. Measured sharpness in the lower third: 57 -> 310 against a
   plain stretch.

A silent programmatic downscale by the agent is the usual cause of a "blurry"
result. Always check the native size of the file in `generated_images/`.

## Identity preservation from a reference

**One frontal reference holds only for a frontal pose.** At three-quarter and
profile angles the model invents geometry it has never seen, similarity drifts,
and effort does not fix it (checked across three efforts).

Practical rules: keep the face nearly square to the camera in the scene (the body
may turn); for other angles, obtain a second reference from that angle and pass
both, one `image=` line each.

## Transparency

True alpha is available only on the paid CLI path with an API key. Asked directly
for an alpha channel, the built-in generator answers that it does not support a
native transparent background and offers a chroma key instead. So do not promise
"I will just ask for it with no background".

> **A soft-matte chroma-key script can make parts of the OBJECT
> semi-transparent** when the object's colour is in the same family as the key.
> A matte that derives alpha from channel dominance rather than distance to the
> key colour — `alpha = 1 - (g - max(r,b)) / (255 - max(r,b))` — gave a green
> object an alpha of 130/255 across **100% of its pixels**. On a dark background
> that reads as "the colour went dull", not as a defect.
>
> **Check a cutout by the alpha ON THE OBJECT, not at the corners and edges.**
> Take the pixels of a coloured detail and look at the mean alpha and the share of
> `alpha<250`. With this defect the corners, the transparent-pixel share and the
> green fringe all look perfect.
>
> A workaround is a matte keyed on Euclidean distance to the key colour, plus a
> connectivity constraint (flood-fill the background from the frame border), with
> despill applied only at the boundary. That raises alpha to 242-254, but still
> eats colour at the edges of coloured details. For anything that matters, a
> dedicated background-removal tool beats a hand-rolled script.

## Mechanics and traps

- The built-in generator works **without an API key**. Do not switch to the
  script-based CLI fallback: it requires a key you do not have.
- The file is created in `$CODEX_HOME/generated_images/`, and the agent
  **copies** it to the path you gave. A target path in the prompt is mandatory,
  otherwise the asset stays outside the project.
- Never overwrite an existing asset — use a versioned name (`hero-v2.png`).
- Editing and variations from a reference use the `image` field of the request;
  several references means several `image=` lines. There is no argument-order
  trap: the runner builds the `--image=FILE` form with an equals sign. That form
  is deliberate — `-i` is declared variadic (`-i, --image <FILE>...`), so in the
  space-separated form it can swallow the next argument as another filename. The
  `=` form takes exactly one value and cannot.
- In a `workspace-write` directory the agent leaves empty `.git` and `.agents`
  directories. Remove them afterwards — but run `ls -a` **before** the call
  first: if the asset directory is itself a repository, a worktree or a
  submodule, deleting `.git` destroys history.
- `workspace-write` opens the **whole** working root for writing, not one PNG.
  Point `-C` at the asset directory, never at a project root.
- Write the brief like an art director: purpose, composition, palette, style,
  and what must NOT be in the frame. **State a strict style literally** — "flat
  vector" without qualification still yields gradients and soft shadows.
- A refusal from the generator (quota, unavailability) cannot be talked around by
  rephrasing. Say so instead of trying to work around it.

**Checking the result is mandatory: open the image and look at it.** File size
and resolution reveal neither a broken composition, nor unreadable text, nor
something unwanted in the frame, nor a substituted style.

## Removing the background from EXISTING images

For real photographs and any finished bitmap with a complex background. This is a
different path from generated images, which are cut with a chroma key as
described above. Use a local background-removal model when regenerating is not an
option: a pixel-accurate cutout with no repainting, and — since it runs locally —
client photographs never leave the machine.

A widely available option is `rembg`. Two practical notes from using it:

- `python -m rembg` does not work (the package has no `__main__`), and the
  console script is often installed outside `PATH`. The reliable form is the
  Python API:

```bash
python - <<'EOF'
from rembg import remove
import pathlib
src = pathlib.Path(r'<full input path>.png')
dst = pathlib.Path(r'<full output path>-nobg.png')  # versioned name; never overwrite the input
dst.write_bytes(remove(src.read_bytes()))
print('done:', dst)
EOF
```

- Fine edges (hair, fur): `remove(data, alpha_matting=True)`.
- Specialised models: people and portraits —
  `remove(data, session=new_session('u2net_human_seg'))`; anime and illustration
  — `isnet-anime`; higher quality — `birefnet-general`. A new model downloads on
  first use and works offline afterwards.
- Mask only, for further processing: `remove(data, only_mask=True)`.
- Check the result the same way as anywhere else: open the output and look at it,
  then confirm the mode is RGBA and check the share of transparent pixels in the
  alpha histogram.
