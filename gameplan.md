# Tabletop Siege: a VR game plan

A VR game on Quest 3 that puts the engine's physics, procedural textures and post
chain to work together. Working title.

## The game

A toy castle about 1 m tall stands on a stone plinth 3 m in front of you. You knock
it down from behind a throwing line, with a limited number of stones.

- **Throwing by hand:** squeeze near a basket at your hip to pick up a stone, and let
  go to throw it.
- **Catapult:** a small catapult stands beside you. Pull its arm down by hand, put a
  stone in the cup and let go. A hinge joint and a counterweight do the rest.
- **Score:** soldiers knocked off the plinth, plus the mass of castle that falls off it.
- **Levels:** three, with 8 stones each: a wooden palisade, a stone keep, a tall bell
  tower.
- **Passthrough:** A turns it on and the castle stands on your real floor. Without it
  you are on a hill at sunset.

Blocks are 8-12 cm, about the smallest the solver stacks reliably since the
small-cubes fix. The castle is out of reach, so the skill is aiming, not pushing.

## Physics

- Walls are welded block groups with `breakForce` and `breakTorque`, so they break
  into chunks along the welds instead of block by block.
- Stone welds are strong; wooden beams are weak and snap first.
- `onJointBreak` drives the dust, the haptics and the score.
- The castle sleeps until it is hit.
- The banner on top is a soft body. The catapult arm is a `'hinge'` joint with a
  `range`.

## Textures

All generated in the script, so the game runs on a clean checkout.

- Stone: a cell pattern for the mortar plus noise, a normal map from that height, and
  per-block variation with `uvVariants`.
- Wood planks: grain stripes and knots.
- The plinth: moss and grass. The banner: cloth.

## Post-processing

Only what is comfortable in a headset.

- **Use:** AgX tone mapping and a warm sunset grade; light bloom on glowing things; a
  short slow motion when the keep falls (`timeScale` 0.3, head tracking stays real
  time), with the grade desaturating slightly.
- **Skip:** camera shake, chromatic aberration, heavy vignette, motion blur and depth
  of field. In VR they cause sickness or fight what the eyes already do. The impact
  comes from the castle really falling and from haptics instead.

## Effects and HUD

- **Dust:** a pool of small cubes sharing one mesh, instanced into one draw, moved
  with `three.batch` and faded out. There is no particle system.
- **Scoreboard:** seven-segment digits made of glowing boxes on a banner pole. The UI
  layer is split across the two eyes (plan.md §4), so the score lives in the world.

## Engine work

- [x] **Grab lag.** `three.xr.right.track(palm)` keeps a kinematic body on the hand,
      placed before the physics step, so what it holds is where the hand is this
      frame. Kinematic velocities are now right above 60 Hz (they were half at 120).
- [x] **Physics at the display rate.** `three.physics.rate = three.xr.refreshRate`.
      At the fixed 60 Hz a held stone moved on every other frame of a 120 Hz display.
      Each step costs the same, so 90 Hz is 1.5x the physics time: milestone 0
      measures it.
- [x] **Hand velocity.** `grip.velocity` and `grip.angularVelocity`, read from
      OpenXR's `XrSpaceVelocity`, and worked out from the poses for synthetic and
      emulated hands. Not yet tried on the headset.
- [x] **Bloom bleeding between eyes** (plan.md §4). Each post pass now runs once
      per eye on that eye's layer of every chain image: a blur clamps at the eye's
      edge, `p.uv` is the eye's, a history is per eye, and the side-by-side copy
      the passes used to need is gone.
- [x] **Fast stones through moving blocks.** The probe found it: a 3 cm stone went
      through a free 10 cm block at 25 m/s and a 3 cm plank at 40 m/s, depending on
      where its substeps landed. The sweep now covers moving bodies too, in their own
      frame, and keeps the stone's speed so the block takes the momentum (clamping
      it away the way the static sweep does handed on a sixth of the hit).
- [x] **Solver speed** (found by the milestone 0 probe). A welded castle being hit
      cost 96 ms a frame at 100 blocks on the Quest. Now 5-6 ms:
      - A sleeping island's welds are no longer solved every substep.
      - The broad phase tests boxes before handing a pair on (a 2 m cell holds
        the whole castle, so every pair of blocks was reported).
      - Box against box is a separating-axis test instead of GJK plus EPA.
      - The solver's vector maths is inlined; the std methods are weak symbols
        LLVM never inlines. A cube's world inertia is its local one.
      - A weld's three angular axes are one constraint. Its linear axes stay
        three: as one, a welded stack never settled.
      - Steps that run slower than real time are not caught up on: the next
        frame takes one, so the world slows down instead of the frame rate
        falling to 3 fps.
- [ ] **Audio.** The engine has none, and a physics game feels hollow without impact
      sounds. A feature of its own (AAudio on Quest, CoreAudio on the Mac); haptics
      stand in until then.

## Milestones

Each is pushed with `quest.sh push`, checked over MCP on the headset, and run on the
desktop with `--xr-emulate`.

0. **Physics probe.** Done: `examples/siege/probe.js` builds a ring of 10 cm blocks
   welded to the one below and beside, throws stones at it, then lets every block go.
   Solver milliseconds a frame on the Quest 3, 4 substeps, one step a frame:

   | Blocks | Standing | Being hit, 90 Hz | Falling, 90 Hz | Being hit, 120 Hz |
   |--------|----------|------------------|----------------|-------------------|
   | 100    | 0.6      | 6.0              | 3.8            | 5.3               |
   | 200    | 1.1      | 9.1              | 7.4            | 8.8               |
   | 300    | 1.7      | 10.8             | 9.9            | 12.6              |

   The rest of the frame is about 0.8 ms. The Quest is 3.5x slower than an M-series
   Mac per step.

   **Decided from it:**
   - The display runs at 90 Hz (11.1 ms), the world steps at 90.
   - About 200 blocks in a level, welded in sections (a wall, a tower) that are not
     welded to each other, so a hit wakes one section and not the castle.
   - Slow motion on the big collapse is also the budget: at `timeScale` 0.3 the
     world takes a third of the steps.

   Still slow, for later: a standing castle costs 1.7 ms at 300 blocks, nearly all of
   it the broad phase scanning one 2 m cell (a cell size per world would fix it), and
   one island solves on one thread.
1. **Throwing.** The basket, the stones, the throw with hand velocity, haptics.
2. **Castle and textures.** One builder (`buildWall`, `buildTower`) for all three
   levels, and the materials.
3. **The catapult.**
4. **Game loop.** Score, stones left, reset on B, level select, the scoreboard.
5. **Post and polish.** Grade, bloom, slow motion, dust. Measure the cost: any script
   pass makes the headset copy both eyes into one image first.
6. **Passthrough mode,** and a check that the grade does not tint the real room.

## Open decisions

Defaults until decided otherwise:

- **Scale:** a toy castle at real size. The alternative, "giant mode" (a life-size
  castle with the player 20x taller), needs a rig scale (`three.xr.scale`) applied
  to the eyes, hands and eye separation.
- **Catapult:** in the first version, as milestone 3.
- **Audio:** after the first playable version.
