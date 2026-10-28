#!/usr/bin/env python3
"""Build the minimal Apple Device Tree that the SANTONI xnu needs to boot.

Only what the early boot path actually reads (see NOTES.md); every MMIO
address comes from the santoni (Redmi 4X, MSM8937) live FDT.
Usage:  mkadt.py OUT.adt [--dump] [--qemu] [--native]
"""
import hashlib, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adt  # noqa: E402

# ---- per-board profile -----------------------------------------------------
# Verified against each phone's live /proc/device-tree (see NOTES.md).
# Everything not listed is identical across the family: SDCC1 at
# 0x7824000/0x7824900, QGIC2 at 0xb000000, APPS watchdog at 0xb017000,
# GCC at 0x1800000, boot cluster1 core0 (MPIDR 0x100).
BOARDS = {
    'santoni': dict(
        # Redmi 4X (MSM8937). DRAM bank1 0x80000000+2 GiB; kernel RAM above the
        # Qualcomm XPU carve-outs which end at 0x92280000.
        phys_base=0x98000000, mem_size=0x28000000,  # 640 MiB safe budget
        fb=0x90001000, fb_w=720, fb_h=1280, fb_bpp=3,  # BGR24
        model='santoni', ecid=0x53414e544f4e4901, display_scale=2,
    ),
    'oxygen': dict(
        # Mi Max 2 (MSM8953). Carve-outs run to the splash region ending at
        # 0x91400000; the free gap 0x91400000..0xb0000000 (492 MiB) holds XNU.
        phys_base=0x91400000, mem_size=0x1ec00000,  # 492 MiB
        fb=0x90001000, fb_w=1080, fb_h=1920, fb_bpp=4,  # BGRA32
        model='oxygen', ecid=0x4f585947454e0201, display_scale=3,
    ),
}
BOARD = 'santoni'

# /arm-io children are relative to this; it must not be 0 (serial_init bails)
SOC_BASE = 0x01000000

# interrupt-controller@b000000 (QGIC2, identical on MSM8937/MSM8953)
GICD, GICD_SIZE = 0x0b000000, 0x1000
GICC, GICC_SIZE = 0x0b002000, 0x1000
TIMEBASE = 19200000
VTIMER_INTID = 20
# QEMU virt (-M virt,gic-version=2 -cpu cortex-a53): GICD/GICC and the generic timer's CNTFRQ
QEMU_GICD, QEMU_GICC, QEMU_TIMEBASE = 0x08000000, 0x08010000, 62500000
QEMU_VTIMER_INTID = 27

BOOT_MANIFEST_HASH = hashlib.sha384(b'santoni boot manifest').digest()

# ---- iOS userland identity --------------------------------------------------
# The iOS userland comes from a donor iPhone IPSW. MobileGestalt derives product
# type, device class, Home-button UI, artwork etc. from the root identity and
# /product of the real donor device tree. Those trees are Apple artifacts (kept
# out of git): extract with
#   tools/remotezip.py URL DeviceTree.<dt>.im4p DIR
#   ipsw img4 im4p extract DIR/Firmware/all_flash/DeviceTree.<dt>.im4p -o <dt>.adt
#
# Per-board donor:
#   santoni -> iPhone X   (iPhone10,3 / D22AP, A11 = chip-id 0x8015, no Home button)
#   oxygen  -> iPhone 8+  (iPhone10,2 / D21AP, A11 = chip-id 0x8015, Home button,
#                          1080x1920 panel == the phone's panel, so sweetfb_native
#                          maps 1:1)
IDENTITY = {
    'santoni': dict(dt='D22AP', model='iPhone10,3', product='iPhone10,3',
                    target_type='D22', target_sub='D22AP', chip_id=0x8015,
                    home_button_type=2, adt='../research/ipsw-x/d22ap.adt'),
    'oxygen': dict(dt='D21AP', model='iPhone10,2', product='iPhone10,2',
                   target_type='D21', target_sub='D21AP', chip_id=0x8015,
                   home_button_type=1, adt='../research/ipsw-8plus/d21ap.adt'),
}


def donor_adt_path(board):
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), IDENTITY[board]['adt'])


def d22ap_product(board):
    """/product properties of the real donor tree, without the syscfg
    placeholders iBoot would fill in (flag bit set) and the node bookkeeping."""
    path = donor_adt_path(board)
    if not os.path.exists(path):
        print(f'warning: {path} missing, no /product node', file=sys.stderr)
        return None
    root, _ = adt.parse(open(path, 'rb').read())
    for c in root.children:
        if dict((k, v) for k, f, v in c.props).get('name') == b'product\0':
            return [(k, v) for k, f, v in c.props if not f and k not in ('name', 'AAPL,phandle')]
    raise SystemExit(f'{path}: no /product node')

u32 = lambda *v: struct.pack('<%dI' % len(v), *v)
u64 = lambda *v: struct.pack('<%dQ' % len(v), *v)
cstr = lambda s: s.encode() + b'\0'


def node(name, props=(), children=()):
    n = adt.Node()
    n.props = [('name', 0, cstr(name))] + [(k, 0, v) for k, v in props]
    n.children = list(children)
    return n


def build(seed=None, qemu=False, native=False, board=BOARD):
    """qemu=True: same tree, but with QEMU virt's GIC addresses and CNTFRQ (tools/qemu-sweet.py)."""
    prof = BOARDS[board]
    ident = IDENTITY[board]
    phys_base, mem_size = prof['phys_base'], prof['mem_size']
    FB, FB_W, FB_H, FB_BPP = prof['fb'], prof['fb_w'], prof['fb_h'], prof['fb_bpp']
    FB_SIZE = FB_W * FB_H * FB_BPP
    FB_STRIDE = FB_W * FB_BPP
    SWEET_ECID = prof['ecid']
    gicd, gicc, timebase = (QEMU_GICD, QEMU_GICC, QEMU_TIMEBASE) if qemu else (GICD, GICC, TIMEBASE)
    seed = seed if seed is not None else os.urandom(64)
    phandle = iter(range(1, 1000))
    ph = lambda: ('AAPL,phandle', u32(next(phandle)))

    chosen = node('chosen', [
        ph(),
        ('dram-base', u64(phys_base)),
        ('dram-size', u64(mem_size)),
        ('random-seed', seed),
        ('debug-enabled', u32(1)),
        ('firmware-version', cstr(board + '-shim')),
        ('system-firmware-version', cstr(board + '-shim')),
        # iBoot's SHA-384 of the boot manifest; /sbin/mount -P 1 exits unless
        # it exists (bind mounts /private/preboot/<hex>/usr/standalone/firmware,
        # tolerating a missing directory). Fixed stand-in value.
        ('boot-manifest-hash', BOOT_MANIFEST_HASH),
        # libimg4 (cryptexd) aborts "failed to get crypto algorithm" without
        # it; real A11+ device trees say sha2-384.
        ('crypto-hash-method', cstr('sha2-384')),
        # MobileGestalt's screen class: display-scale (u32, default 0) comes
        # from /chosen, the pixel size from IOMobileFramebuffer. Santoni's
        # 720x1280 panel is @2x; oxygen's 1080x1920 is @3x (360x640 points).
        ('display-scale', u32(prof['display_scale'])),
        # XNU derives IOPlatformUUID (gethostuuid) from these on arm; without
        # them CFPreferences cannot use kCFPreferencesCurrentHost (no ByHost
        # files), so e.g. DataMigration never records LastSystemVersion and
        # migrates on every boot. Synthetic ECID (not the phone's); chip-id
        # of the A11 that the iPhone X userland expects.
        ('unique-chip-id', struct.pack('<Q', SWEET_ECID)),
        ('chip-id', u32(ident['chip_id'])),
        # Security status as on a dev-fused, undemoted board (tuple 0,0,1,1):
        # MobileGestalt reads these from /chosen, and mobileactivationd's
        # DeviceType then takes its native "Hactivation" branch (state
        # Activated without an activation record; no SEP, no baseband here).
        ('certificate-production-status', u32(0)),
        ('effective-production-status-ap', u32(0)),
        ('certificate-security-mode', u32(1)),
        ('effective-security-mode-sep', u32(1)),
    ], [node('memory-map', [ph()]),
        # Local boot policy (kern_csr.c): SIP relaxed like `csrutil disable`
        # (lp-sip0: untrusted kexts, unrestricted FS, task_for_pid, kernel
        # debugger, dtrace, nvram), lp-sip1: unauthenticated (unsealed) root.
        # The iOS shared cache is in no trust cache, so dyld can only map it
        # with CSR_ALLOW_UNRESTRICTED_FS (vm_unix.c shared region checks).
        node('asmb', [ph(), ('lp-sip0', u64(0x6f)), ('lp-sip1', u32(1))])])

    # Qualcomm MSM8937 Octa-core Cortex-A53
    # LK boots on Cluster 1 Core 0 (MPIDR 0x100).
    # XNU and SweetCPU require the boot CPU to be logical CPU 0.
    # List Cluster 1 (0x100-0x103) as cpu0-cpu3, and Cluster 0 (0x000-0x003) as cpu4-cpu7.
    cpu_phys_ids = [0x100, 0x101, 0x102, 0x103, 0x000, 0x001, 0x002, 0x003]
    cpu_nodes = []
    for i, phys_id in enumerate(cpu_phys_ids):
        cluster = phys_id >> 8
        core = phys_id & 3
        clk = 1401600000 if cluster == 1 else 1094400000
        # By default, Core 4 (0x100) is marked running because LK boots on the high-performance cluster.
        # Bare-metal shim loader dynamically updates state based on live MPIDR_EL1.
        state = 'running' if phys_id == 0x100 else 'stopped'
        cn = node(f'cpu{i}', [
            ph(),
            ('device_type', cstr('cpu')),
            ('compatible', cstr('arm,cortex-a53') + cstr('qcom,kryo470') + cstr('ARM,v8')),
            ('reg', u32(phys_id)),
            ('cpu-id', u32(i)),
            ('cluster-id', u32(cluster)),
            ('cluster-type', u32(0)),
            ('die-cluster-id', u32(cluster)),
            ('cluster-core-id', u32(core)),
            ('l2-cache-id', u32(cluster)),
            ('l3-cache-id', u32(0)),
            ('state', cstr(state)),
            ('timebase-frequency', u32(timebase)),
            ('clock-frequency', u32(clk)),
            ('bus-frequency', u32(100000000)),
            ('memory-frequency', u32(933000000)),
            ('peripheral-frequency', u32(timebase)),
            ('fixed-frequency', u32(timebase)),
        ])
        cpu_nodes.append(cn)
    cpus = node('cpus', [ph(), ('#address-cells', u32(1)),
                         ('#size-cells', u32(0))], cpu_nodes)

    gic = node('gic', [
        ph(),
        ('compatible', cstr('qcom,msm-qgic2') + cstr('arm,gic-400')),
        ('interrupt-controller', b''),
        ('#interrupt-cells', u32(3)),
        ('virtual-timer-intid', u32(QEMU_VTIMER_INTID if qemu else VTIMER_INTID)),
        ('reg', u64(gicd - SOC_BASE, GICD_SIZE, gicc - SOC_BASE, GICC_SIZE)),
    ])
    arm_io = node('arm-io', [
        ph(),
        ('device_type', cstr('sweet-io')),
        ('compatible', cstr('sweet-io') + cstr('arm-io')),
        ('#address-cells', u32(2)),
        ('#size-cells', u32(2)),
        ('ranges', u64(0, SOC_BASE, 0x100000000 - SOC_BASE)),
    ], [gic,
        # No hardware: watchdogd checks IODeviceTree:/arm-io/wdt for no-pmu and
        # otherwise crashes trying to set the PMU boot stage (customer builds
        # ignore the -wdt_no_pmu boot-arg).
        node('wdt', [ph(), ('no-pmu', u32(1))]),
        # Main display: IOMobileFramebuffer.framework counts /arm-io children
        # with this device_type and reads the canvas size from the node
        # (the presented iPhone X size, see SweetFramebuffer.cpp);
        # the kernel's AppleCLCD matches the compatible string.
        # launchd starts wifid only when the device tree has a "wlan" node
        # (com.apple.wifid _LimitLoadToDeviceTree = wlan, marconi-wifi)
        node('wlan', [
            ph(),
            ('device_type', cstr('wlan')),
            ('compatible', cstr('qcom,wcn3680')),
        ]),
        node('disp0', [
            ph(),
            ('device_type', cstr('display-subsystem')),
            ('compatible', cstr('sweet,display')),
            ('canvas-width', u32(FB_W if native else 1125)),
            ('canvas-height', u32(FB_H if native else 2436)),
        ])])

    fbcon = node('sweet-fbcon', [
        ph(),
        ('reg', u64(FB, FB_SIZE)),
        ('width', u32(FB_W)),
        ('height', u32(FB_H)),
        ('stride', u32(FB_STRIDE)),
        ('depth', u32(FB_BPP * 8)),
    ])

    # Internal eMMC 5.1 controller (SDCC1) for bsd/dev/santoni_sdhci.c. At the
    # root, like /sweet-ufs, so reg[] is an absolute physical address and not
    # translated by /arm-io's "ranges". The 0x1000 window starting at the
    # Qualcomm core block also contains the standard SDHCI host controller
    # registers at 0x07824900 (+0x900, 0x500 bytes); hc-reg mirrors the
    # msm8937.dtsi sdhc_1 split for documentation.
    sdhci = node('santoni-sdhci', [
        ph(),
        ('compatible', cstr('qcom,sdhci-msm-v4') + cstr('generic-sdhci')),
        ('device_type', cstr('sdhci')),
        ('reg', u64(0x07824000, 0x1000)),
        ('hc-reg', u64(0x07824900, 0x500)),
        ('bus-width', u32(8)),
        ('non-removable', b''),
    ])

    # pmap_compute_max_asids requires the node even when no overrides are set.
    # An absent pmap-max-asids property selects XNU's own MAX_ASIDS default.
    # No effaceable storage: keybagd then reads /private/var/keybags/systembag.kb
    # as a plain plist instead of decrypting it with the effaceable key.
    defaults = node('defaults', [ph(), ('no-effaceable-storage', u32(1))])

    # MobileGestalt HomeButtonType = IODeviceTree:/buttons home-button-type.
    # The real donor trees say iPhone X (D22AP) = 2 (no Home button) and
    # iPhone 8 Plus (D21AP) = 1 (Home button); copy the donor's value.
    # (Absent = 0, which is not what the 8 Plus userland expects.)
    button_props = [ph(),
                    ('button-names', cstr('volup') + cstr('voldown') + cstr('hold')),
                    ('opposed-power-vol-buttons', u32(1))]
    if ident['home_button_type'] is not None:
        button_props.append(('home-button-type', u32(ident['home_button_type'])))
    buttons = node('buttons', button_props)

    product_props = d22ap_product(board)
    # Our framebuffer is sRGB 8-bit. With the iPhone X's 'P3' MobileGestalt says
    # HasExtendedColorDisplay and WebKit renders page tiles into 10-bit surfaces
    # ('w30r', 'b3a8') that this kernel does not provide: Safari pages stay blank.
    if product_props:
        product_props = [(k, cstr('sRGB') if k == 'artwork-display-gamut' else v) for k, v in product_props]
    product = [node('product', [ph()] + product_props)] if product_props else []

    # Identity of the donor iPhone whose userland runs here: compatible[0] is
    # hw.model/hw.target, model is hw.machine/hw.product. 'xiaomi,<board>' and
    # the qcom SoC match the target silicon.
    soc = {'santoni': 'qcom,msm8937', 'oxygen': 'qcom,msm8953'}[board]
    return node('device-tree', [
        ph(),
        ('compatible', cstr(ident['dt']) + cstr(ident['product']) + cstr('xiaomi,' + board) + cstr('xiaomi,sweet') + cstr(soc) + cstr('AppleARM')),
        ('model', cstr(ident['model'])),
        ('target-type', cstr(ident['target_type'])),
        ('target-sub-type', cstr(ident['target_sub'])),
        ('manufacturer', cstr('Apple Inc.')),
        ('#address-cells', u32(2)),
        ('#size-cells', u32(2)),
    ], [chosen, defaults, cpus, arm_io, fbcon, buttons, sdhci] + product)


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: mkadt.py OUT.adt [--dump] [--qemu] [--native] [--board NAME]", file=sys.stderr)
        sys.exit(1)
    board = 'santoni'
    if '--board' in sys.argv:
        i = sys.argv.index('--board')
        board = sys.argv[i + 1]
        if board not in BOARDS:
            raise SystemExit(f'unknown --board {board}; choices: {sorted(BOARDS)}')
    root = build(qemu='--qemu' in sys.argv, native='--native' in sys.argv, board=board)
    blob = adt.serialize(root)
    out_path = sys.argv[1]
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    open(out_path, 'wb').write(blob)
    if '--dump' in sys.argv:
        adt.dump(adt.parse(blob)[0])
    print(f'{out_path}: {len(blob)} bytes (board={board})', file=sys.stderr)
