# NARUTO SHIPPUDEN: ULTIMATE NINJA STORM 4 ROAD TO BORUTO (`01003F800CF5C000`)

Switch update 1.1.0 (v65536), SDK 8.2.1, NVN API 53.312, `main` build `d3016fc0c0402dfb70fba6b826ea772f`. CyberConnect2's engine presents through NVN and uses OpenGL ES 3.0 for the UI. The two renderers share textures and fences.

## What it needs

| Setting | Where | Why |
|---|---|---|
| 5 GiB reservation, 2.375 GiB alias region, 32 MiB system resource | [`game.tsv`](game.tsv) | The NPDM enables virtual address memory. A Mac boot measured a 2.03 GiB heap request. The configured heap region is 2.125 GiB. |
| NVN and GLSL libraries | [`gl_capture.tsv`](gl_capture.tsv) | The standard splitter finds 463 NVN stages, including 25 compute shaders. The game's OpenGL renderer compiles 387 GLSL stages at startup. |
| Modules `main`, `subsdk0`, `sdk` | [`game.tsv`](game.tsv) | `subsdk0` is NintendoSDK_movie. The host answers the GL imports. |

## Found on this game

- [An NVN sync fenced again exports a null GL fence](../../../docs/reference/rendering.md#an-nvn-sync-fenced-again-exports-a-null-gl-fence). The fix restores the title logo and button prompt.
- [A generated profile omits the OpenGL library from the app](../../../docs/reference/packing.md#a-generated-profile-omits-the-opengl-library-from-the-app). Both bundles need the OpenGL library for the game's UI.

## Mac gameplay

The packaged Mac app reached active offline combat on an Apple M4 Pro with macOS 27.2.1 at 1600 × 900. The match showed both Naruto fighters, their Sasuke and Sakura support portraits, and the village arena. The app exited cleanly. From Game Mode Select, open **Free Battle**, choose an offline versus match against the CPU, then pick both teams and a stage. On the Mac keyboard, J confirms and K goes back. The game presents its license on first launch before opening the mode menu.

The 500-frame window around the battle capture had a median frame time of 41.78 ms (23.9 fps). A later 300-frame window in the same run had a median of 33.28 ms (30.0 fps). The title ran at about 24 fps before and after the fence fix.

The Mac app and unsigned IPA for 1.1.0 both contain the NVN and OpenGL libraries and the full RomFS. Other modes and physical iOS devices remain untested.

Startup logs a rejected GL sync deletion, a skipped NVN upload at mip level 6 on a texture with six levels, and a missing pipeline prewarm list. The pictured battle rendered with these warnings present.
