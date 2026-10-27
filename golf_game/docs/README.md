# Visual review

`menu.png` and `range.png` are captured from the native Linux release executable,
not mockups. They document the current art direction and default High preset.
`follow.png` is captured by the deterministic follow-sequence review helper during
rollout. It shows the same range scene and materials, with the rendered ball's
bottom checked against the shared turf-surface height.
It also demonstrates whole-object transparency with a stable follow camera.
`flight.png` shows the interpolated soft trail and a shot with 1,800 RPM right-side
spin, using the same deterministic review helper.
`cup.png` shows a one-metre opening during the ball's drop animation. Its lining,
bottom, rim and grass/terrain cutout use the saved map diameter.
`hole_builder.png`, `hole_blank.png`, and `custom_hole.png` are captured from the
native release's integrated authoring/play modes. `hole_result.png` is a gameplay
review capture of the automatic-green scoring panel.

To reproduce a capture after building:

```bash
dist/pinewater/0.2.0/Pinewater-linux/Pinewater -- --capture-app /tmp/menu.png
dist/pinewater/0.2.0/Pinewater-linux/Pinewater -- --range --capture-app /tmp/range.png
```

Use a graphical desktop. The headless application smoke test is a separate check.

```bash
godot --path golf_game --script res://tests/capture_follow.gd -- /tmp/follow.png --rolling
```
