# Community Post Drafts
> Post these AFTER macOS Tahoe is confirmed booting and installing.
> Update [STATUS] placeholders before posting.

---

## r/Proxmox
**URL:** https://reddit.com/r/Proxmox/submit
**Title:** Built a script to automate macOS Tahoe on Proxmox for AMD — looking for testers

> I got tired of hitting the same walls every time I tried to get macOS running on Proxmox with an AMD CPU. Wrong CPU flags, kernel panics, core count hangs at the Apple logo, the osx-proxmox-next tool failing silently on recovery ISO format mismatches — none of this is documented in one place.
>
> So I wrote a script that handles the full setup non-interactively:
>
> **https://github.com/wlfogle/proxmox-macos**
>
> What it does differently from other guides:
> - Core count forced to power-of-2 (6 cores silently hangs AMD at Apple logo)
> - `+invtsc` applied for AMD TSC sync (kernel panic without it)
> - Uses `Cascadelake-Server` emulation instead of `-cpu host` (30–44% faster for macOS per benchmarks)
> - Catches the osx-proxmox-next recovery ISO stamping failure (HFS+ expected, ISO 9660 provided) and continues rather than aborting
> - Headless-friendly: installs via noVNC, then `--enable-gpu` adds passthrough after NomMachine is running
> - Idempotent — re-run anytime to fix config without destroying the VM
>
> Tested on: Ryzen 5 3600 + RX 580 + Proxmox 9.2.3. [STATUS: currently validating the full install]
>
> If you've been struggling with macOS on Proxmox + AMD, give it a try and let me know what breaks. Happy to fix issues.

---

## r/hackintosh
**URL:** https://reddit.com/r/hackintosh/submit
**Title:** Automated macOS Tahoe setup on Proxmox/KVM for AMD — script + notes on what silently breaks

> Getting macOS Tahoe running on Proxmox with an AMD CPU has a handful of non-obvious failure modes that cost me a lot of time. Sharing a script and the notes in case they help others.
>
> **The AMD-specific gotchas:**
>
> 1. **Core count must be power-of-2.** macOS kernel hangs at the Apple logo with 6, 10, 12 cores. Use 4 or 8.
> 2. **`+invtsc` is mandatory.** Without the invariant TSC flag, AMD gets kernel panics during boot.
> 3. **`-cpu host` is slower than a named model.** Using `Cascadelake-Server,vendor=GenuineIntel` gives 30–44% better single/multi-core scores vs `-cpu host` with feature masking.
> 4. **WhateverGreen breaks Tahoe install.** Use `MacPro7,1` SMBIOS (no WhateverGreen needed) rather than `iMac20,2` which requires it.
> 5. **Recovery ISO format matters.** Tools expect HFS+; if you have an ISO 9660 recovery image the stamping step fails — VM is still fully created though.
>
> Script that handles all of this: **https://github.com/wlfogle/proxmox-macos**
>
> [STATUS: install in progress on Ryzen 5 3600 + RX 580 — will update with results]
>
> Would love feedback from others with different AMD hardware.

---

## r/homelab
**URL:** https://reddit.com/r/homelab/submit
**Title:** Automating macOS Tahoe on Proxmox — script for AMD setups, headless friendly

> Quick share for anyone running an AMD-based Proxmox server who wants a macOS VM without the usual 4-hour config nightmare.
>
> **https://github.com/wlfogle/proxmox-macos**
>
> The script wraps osx-proxmox-next with all the AMD-specific fixes baked in, plus handles the headless case (no physical monitor — install via noVNC, then enable GPU passthrough after your remote access software is set up).
>
> Currently testing on Ryzen 5 3600 + RX 580 + Proxmox 9.2.3 + macOS Tahoe 26.5.1. Will update once the install is confirmed working.
>
> If you try it on different hardware, let me know how it goes.

---

## Proxmox Community Forum
**URL:** https://forum.proxmox.com/forums/general.7/
**Title:** [SCRIPT] macOS Tahoe on Proxmox — AMD CPU, RX 580 passthrough, headless

> Hello,
>
> I've been working on automating the macOS Tahoe VM setup on Proxmox for AMD hardware, and I'm sharing the script for community feedback.
>
> **https://github.com/wlfogle/proxmox-macos**
>
> The main problems this script addresses vs. following existing guides manually:
>
> - AMD CPUs need `Cascadelake-Server,vendor=GenuineIntel` in QEMU args, not `-cpu host`
> - Core count must be power-of-2 or the kernel hangs silently at the Apple logo
> - `+invtsc` is required for AMD TSC synchronisation
> - osx-proxmox-next exits with code 4 when the recovery image is ISO 9660 (it expects HFS+), but the VM is fully created — the script catches this and continues
> - GPU passthrough and headless access (NomMachine) require a two-phase approach
>
> Currently testing — will report back once macOS Tahoe is confirmed booting. Looking for feedback from others with AMD hardware.
>
> Hardware: Ryzen 5 3600 / RX 580 / Proxmox VE 9.2.3

---

## OSX-KVM GitHub Discussions
**URL:** https://github.com/kholia/OSX-KVM/discussions
**Title:** Script for Proxmox + AMD: handles core count hang, +invtsc, Cascadelake-Server emulation

> Hi — sharing a Proxmox-specific script that builds on OSX-KVM's research and osx-proxmox-next:
>
> https://github.com/wlfogle/proxmox-macos
>
> Key findings for AMD on Proxmox that the script handles automatically:
> - `Cascadelake-Server,vendor=GenuineIntel` is significantly faster than `-cpu host` with feature masking
> - Core count **must** be power-of-2 for macOS (Tahoe hangs at Apple logo with 6 cores)
> - `+invtsc` essential for AMD TSC sync
> - Two-phase GPU passthrough for headless setups
>
> Still validating — posting early for feedback. Will update with full results.

---

## Notes
- Wait for confirmed working install before posting
- Update [STATUS] lines in each post
- Post r/Proxmox first (most relevant audience), then others
- Reply to comments promptly — community goodwill matters more than upvotes
