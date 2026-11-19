# Xenoblade Chronicles 3: changes to its own modules, checked by NSO build ID.
# Nintendo SDK module changes belong to dm/tools/sdk_patches.py.
from nso_asm import ADRP, B

CUTS = {
    # 2.2.0 / 2.2.1 share this main build ID (issue #847; see README.md).
    # nninitStartup reserves 60 GB for Monolith's allocator. Its first
    # arena reserves 4 GB + 128 KB, maps the first 128 KB for bookkeeping, and
    # takes additional pages on demand. iOS cannot reserve that address space.
    # The original arena commits 203 MB at the title and 225 MB in the opening
    # battle. A 1 GB first arena inside a 4 GB container leaves too little room
    # for the battle's 390 MB core buffer: its 512 MB virtual window ends
    # 70.75 MB past the container (12429a4, before any physical mapping).
    # Reserve 512 MB for the first arena and 4 GB for the container, changing
    # the bump increment, subtraction and stored capacity together. This is
    # an address-space adaptation; physical limits still follow the Switch
    # pool. Later-game allocation peaks remain to test.
    '82d187fe9ef9be921b8e1b1cddf7bd28': [
        (0x128e58c, 'e001c0d2', '2000c0d2', 'malloc address region: 60 GB to 4 GB'),
        (0x1241870, 'e98340b2', 'e9ff9fd2', 'first arena bump size, low part: mov x9,#0xffff'),
        (0x1241880, '4900a0f2', '4900a4f2', 'first arena bump size: 512 MB + 128 KB + 64 KB - 1'),
        (0x12418d8, 'e97b5fb2', 'e98361b2', 'first arena subtraction, sign extension'),
        (0x12418dc, 'c9ffbff2', 'c9ffbbf2', 'first arena subtraction: -(512 MB + 128 KB)'),
        (0x12418e8, '2800c0f2', '4800a4f2', 'first arena stored capacity: 512 MB + 128 KB'),
    ],
}

# How general each patch is and could be (dm/tools/docs_patches.py "Binding", listed in docs/agents/game-patches.md): what, its binding now, the loosest it could have (goal),
# purpose, why; blocked or kept: why the gap stays open (cannot close yet, or left open on purpose); checked: what was checked on game files (else a judgement)
BINDING = [
    {'what': 'malloc region 60 GB → 4 GB and its first arena', 'now': 'build', 'goal': 'game', 'purpose': 'address space',
     'why': "Monolith's own allocator; its constants span two functions (a multi-function rule). The cause, an iPhone's address space, is a platform limit"},
    {'what': 'render scale: renderer targets, the in-play scene size and the dynamic resolution\'s cap', 'now': 'build', 'goal': 'game', 'purpose': 'rendering',
     'why': "the game's own size constants and its dynamic-resolution controller, across three functions and two relocations; a function-matched rule would need all of "
            "them found together, and 2.2.1 is the one build here",
     'checked': '2.2.1 main: 1080p (1.5) renders every scene pass at 1920x1080 through the first battle at 59.3 fps with the 60 FPS cheat (Apple M6, 2026-11-18); 2.0 rejected (present crop past the output)'},
]

# Render scale (the launcher's Render scale, DM_RENDER_SCALE, state +0x10, written by the loader; 1.0 by default, which leaves every size as the game sets it), 0.5 to 1.5.
# Docked, the game draws its scene at 1280x720 and its own upscaler takes it to the 1920x1080 output (a battle frame: 487 passes at 1280x720, three at 1920x1080). Three things
# set that size, and the stub changes all three together:
#   - the renderer's constructor (main+0xf654e0) builds its scene-size targets at mov w1,#1280 / mov w2,#720 (main+0xf65518), the largest the scene can take;
#   - in play the scene size comes from a constant pair in .rodata (main+0x14dfd94 1280, +0x14dfd98 720; beside it 1920x1080 for the output) that seven places read through
#     the GOT (main+0x1b65938 / +0x1b65940): main+0xed5a6c and main+0x10377b4 when the renderer starts (0.89 / 0.91 s, after the constructor at 0.82 s), main+0xea84d4 and
#     main+0xed5a98 when the field loads, three more in modes not reached here. Their two RELATIVE relocations (main+0x1480d18 / +0x1480d30) point at state +0x200 / +0x204
#     instead, where the constructor's stub writes the scaled size (1280 and 720 times the scale, each rounded up to a multiple of 8, as the game rounds its own sizes);
#   - the dynamic resolution (main+0xf54b40..: the scale it stores at renderer +0x20a4 / +0x20a8, capped at 1.0 by fminnm at main+0xf54d0c / +0xf54d14) trims the
#     scene from that size when it thinks the GPU is short of time. Above 1.0 it read the larger size as more load than it was: at 1920x1080 it settled at 1344x760 with the
#     GPU at 9 ms of 16.7 (Apple M6, the 60 FPS cheat), so above 1.0 the stub holds its scale at 1.0; at 1.0 and below it runs as the game wrote it.
# 1.5 (1920x1080, the output size) is the largest: at 2560x1440 the game's present crop reached past its 1920x1080 output ("present crop out of bounds" on every
# frame) and the GPU took 46 ms. x16 / x17 / v16 / v17 are unused in both functions
def render_size(ctx):
    here, emit, fs_site, fs_put, ST = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state
    nop = 0xd503201f
    fs_site(0xf65518, '01a08052025a8052')   # mov w1,#1280; mov w2,#720
    start = here(); emit(ADRP(16, here(), ST))
    for w in (0xbd401210,   # ldr s16,[x16,#0x10]       render scale
              0x1e2e1011,   # fmov s17,#1.0
              0x1e202208,   # fcmp s16,#0.0
              0x1e31ce10,   # fcsel s16,s16,s17,gt     none written: 1.0
              0x5280a011,   # mov w17,#1280
              0x1e220231,   # scvtf s17,w17
              0x1e300a31,   # fmul s17,s17,s16
              0x1e280231,   # fcvtps w17,s17
              0x11001e31,   # add w17,w17,#7
              0x121d7231,   # and w17,w17,#~7           scene width, a multiple of 8
              0xb9020211,   # str w17,[x16,#0x200]
              0x52805a02,   # mov w2,#720
              0x1e220051,   # scvtf s17,w2
              0x1e300a31,   # fmul s17,s17,s16
              0x1e280222,   # fcvtps w2,s17
              0x11001c42,   # add w2,w2,#7
              0x121d7042,   # and w2,w2,#~7             scene height
              0xb9020602,   # str w2,[x16,#0x204]
              0x5280a001,   # mov w1,#1280
              0x6b01023f,   # cmp w17,w1
              0x1a81c221,   # csel w1,w17,w1,gt         the constructor's size: never below the game's 1280x720
              0x52805a11,   # mov w17,#720
              0x6b11005f,   # cmp w2,w17
              0x1a91c042):  # csel w2,w2,w17,gt
        emit(w)
    emit(B(here(), 0xf65520))
    fs_put(0xf65518, [B(0xf65518, start), nop], 'renderer scene targets and the in-play scene size (state +0x200 / +0x204): 1280x720 times the host render scale')
    fs_site(0xf54d0c, '0078281e60a620bd2078281e60aa20bd')   # fminnm s0,s0,s8; str s0,[x19,#0x20a4]; fminnm s0,s1,s8; str s0,[x19,#0x20a8]
    start = here(); emit(ADRP(16, here(), ST))
    for w in (0xbd401210,   # ldr s16,[x16,#0x10]       render scale
              0x1e2e1011,   # fmov s17,#1.0
              0x1e312200,   # fcmp s16,s17
              0x540000ad,   # b.le orig (+5)
              0x1e2e1000,   # fmov s0,#1.0              above 1.0: the scene at its full size
              0xbd20a660,   # str s0,[x19,#0x20a4]
              0xbd20aa60):  # str s0,[x19,#0x20a8]
        emit(w)
    emit(B(here(), 0xf54d1c))
    for w in (0x1e287800, 0xbd20a660, 0x1e287820, 0xbd20aa60): emit(w)   # orig: the game's dynamic scale, capped at 1.0
    emit(B(here(), 0xf54d1c))
    fs_put(0xf54d0c, [B(0xf54d0c, start), nop, nop, nop], 'dynamic resolution held at full size above render scale 1.0')
    for rel, target, off in ((0x1480d28, '94fd4d0100000000', 0x200), (0x1480d40, '98fd4d0100000000', 0x204)):
        fs_site(rel, target)
        fs_put(rel, [ST + off, 0], f'GOT entry of the in-play scene {"width" if off == 0x200 else "height"} (relocation addend): state +{off:#x}, not the .rodata constant')
    ctx.render_scale = 1.5

FRAME_STEP = {'82d187fe9ef9be921b8e1b1cddf7bd28': render_size}
