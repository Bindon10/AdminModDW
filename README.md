# AdminModDW

**Chivalry: Deadliest Warrior** server mod: remote admin console and first-person spectator.
**No gameplay changes** -- every gametype is the stock CDW one plus a few server-side hooks,
and nothing about combat, classes, weapons or maps is touched.

This is the Deadliest Warrior port of AdminMod. It is a separate package in a separate SDK
(`CDW\Development\Src\AdminModDW`), not a build flag on the base-game mod.

## Wire compatibility

**The RCON protocol is identical to AdminMod's.** `AOCRCon.uc` is byte-for-byte the same
file in both SDKs and `AOCRConPacket.uc` differs only in two parameter names, so opcode
numbers, payload field order and the auth handshake are unchanged. The same ChivRcon client
works against both servers with no version switch.

Every opcode 0-64 is implemented; nothing was dropped in the port. Where Deadliest Warrior's
game code differs, the handler was reimplemented against it. All deltas are in
`RCON_PROTOCOL.md`.

## What it gives you

**Multiple simultaneous RCON clients on one port.** Vanilla `AOCRCon` is a single `TcpLink`
that stops listening once a client connects, so the second client is dropped at auth.
AdminModDW sets `AcceptClass`, so each connection gets its own session actor with its own
auth state. No extra port, no proxy, no extra process.

**Sessions survive map changes.** Registered in `GetSeamlessTravelActorList`, so clients stay
connected across seamless travel instead of dropping every rotation.

**Opcodes 23-64.** 0-22 are vanilla. 23-28 make an unmodified **ChivAdmin** client work
against the server. 29-64 add player and ban lists, server info, team/spectate control,
mute, pause, autobalance, game speed, match restart, tournament controls, freeze, class and
loadout control, player positions, teleport and slap.

**An audit trail.** Every state-changing command is logged and echoed to *all* connected
clients as `RCONX_ADMIN_AUDIT`, so admins see each other's actions.

**A team list, so nothing has to assume two teams.** `SERVER_INFO` reports the live teams by
index and name. Deadliest Warrior runs one to six depending on the mode and the server's
`?NumTeams=` option — FFA and Duel have exactly one, the tutorial six — so a client can offer
the right rows instead of a fixed pair, and moving someone to a team that does not exist gets
a refusal that names the ones that do.

**Server-side mute that works, and persists.** Vanilla only checks `bIsAdminMuted`
client-side and skips it for the muted player's own copy and for their Steam friends, so
mute looks broken. AdminModDW drops the message on the server, and stores the mute in
`[AdminModDW.AdminModDWRCon]` so it survives a reconnect or a restart.

**Tournament mode, which Deadliest Warrior does not otherwise have** -- including the ready-up
it has no mechanic for. Players type **`!ready`** in chat; the round is held until every
populated team clears the configured threshold, with progress announced in chat. DW's own
`bReady` is deliberately not used: it means "has picked a class and is not in a menu", so
gating on it does nothing. Admins can force-ready or clear everyone over RCON. See
`RCON_PROTOCOL.md` -- notably that it gates every round rather than one, and is runtime-only.

**First-person spectate.** Watch a player from inside their own eyes: left click for the next
player, right click for the free camera, Space to toggle between first person and the vanilla
orbit follow. Health and stamina bars follow whoever you are watching, and the spectator FOV
stays put. `FirstPersonSpectate` and `FPSpectateDebug` are console commands.

## Install

1. Build `AdminModDW` as an SDK mod package in the **Deadliest Warrior** SDK, not the
   base-game one. Deadliest Warrior's game folder is `CDWGame`, not `UDKGame`.
2. Cook it. The output lands in `CDWGame\CookedSDK\AdminModDW_<GUID>\`.
3. Ship that folder. RCON port is the vanilla one -- `[AOC.AOCRCon] RConPort=` in
   `CDWGame\Config\CDWGame.ini` (the section really is `AOC.`, not `CDW.` -- `AOCRCon`
   keeps its class name in this SDK); AdminModDW does not change it.

**If the make does not list AdminModDW, nothing you wrote was compiled.** The SDK Frontend
writes the package list into `CDWGame\Config\CDWSDK.ini` as
`[ModPackages] ModPackages=<name>`, and it ships set to `SDKTestCDW`. If the frontend fails
to rewrite that file -- it logs `[FILE WRITE TO '..\CDWGame\Config\CDWSDK.ini' FAILED]` and
carries on -- the make compiles the stale list, the cook then reports
`Failed to find package ADMINMODDW`, and no error in between mentions your code. Set it by
hand:

    [ModPackages]
    ModPackages=AdminModDW

Check the make output before reading anything else: the package banners at the end of
`make -full` are exactly what got compiled.

Launch the server with `?modname=AdminModDW`. That mounts the package but does **not** pick
the gametype -- the engine still resolves the game class from the map prefix, and the only
hook that redirects it is the `SetGameType` override in `AdminModDWGame.uci`, driven by the
`SDKPrefixes` table in `DefaultAdminModDW.ini`. Without it every mode runs stock CDW with the
mod mounted, and the server browser reads "An Unnamed Mod". Verify a build has it before
diagnosing anything else:

    grep -c SetGameType UDKGame\CookedSDK\AdminModDW_<GUID>\AdminModDW.u

Nine gametypes are covered: TD, TO, FFA, LTS, KOTH, Tutorial, Duel, Plant the Banner and
Hold the Banner. CTF and Horde are not -- Deadliest Warrior has neither, and the `CTF` /
`AOCCTF` entries in its stock ini point at a class that does not exist in this SDK.

Deadliest Warrior registers **both** spellings of every prefix -- `AOCTD-` and `TD-`,
`AOCTO-` and `TO-`, and so on -- and its own maps use the short one. `DefaultAdminModDW.ini`
claims both; a table with only the `AOC*` forms runs vanilla gametypes on half the rotation
with the mod mounted, which reads as "An Unnamed Mod" in the browser.

## Files

| File | Purpose |
|------|---------|
| `Classes/AdminModDWRCon.uc` | The console: opcodes, auth gating, fan-out to sessions, tournament state |
| `Classes/AdminModDWRConSession.uc` | One accepted connection |
| `Classes/AdminModDWAdminActions.uc` | Statics shared by handlers (teleport, slap) |
| `Include/AdminModDWGame.uci` | `SetGameType`, `InitRemoteConsole`, seamless-travel list, `BroadcastMessage`, the tournament `ShouldCountDown` gate |
| `Classes/AdminModDW<Mode>.uc` | Nine thin gametypes: stock CDW + the includes |
| `Classes/AdminModDW<Mode>PlayerController.uc` | Nine thin controllers |
| `Include/AdminModDWPlayerController.uci` | Drunk post-process chain, and the first-person spectator |
| `Include/AdminModDWPawn.uci` | Pawn side of first-person spectate (the feint blend reset) |
| `Classes/AdminModDWPawn.uc` | `AOCPawn` + that include. `AdminModDWTUTPawn` / `AdminModDWDuelPawn` keep vanilla's per-mode parents |

Each mode's `.uci` defines two macros, `GAMEMODE` and `PAWNCLASS`, read by
`AdminModDWGame.uci`'s `DefaultProperties`. Adding a mode means defining both.

## What changed from the base-game AdminMod

Deadliest Warrior is an older branch of the Chivalry codebase, so several things AdminMod
works around simply are not there.

| Area | Base game | Deadliest Warrior |
|---|---|---|
| Teams and classes | A family *is* a faction; `ChangeTeam` always refuses; swap walks `AOCGRI.FamilyInfos` | Colour teams, six team-independent warrior families; `SetNewClass` takes the destination team |
| Tournament mode | Built in (`bTournamentMode`, ready fields on GRI/PRI, `AdminReadyAll`) | Does not exist -- rebuilt here on `bWaitForTeams` / `bReady` |
| 1P mesh for spectate | Stripped by `SetCharacterAppearance`; ~200 lines to rebuild it | Never stripped; `BecomeFirstPersonObserved` assigns it. Rebuild code deleted |
| Camera socket fallback | Hooks `AOCPawn.GetCameraSocketLocationAndRotation` | No such function -- `AOCPlayerCamera` calls the component directly. Replaced by a pre-flight check |
| Idle time | `AOCPRI.IdleTime` | No such field -- computed from `PlayerController.LastActiveTime` |
| Big on-screen text | `ClientShowLocalizedHeaderText` | `ReceiveLocalizedHeaderText` |
| Customization | `CharacterAssetStore`, `AOCCharacterInfo` lookups | Predates it -- `PawnCharacter` only |
| Gametypes | Ten, incl. CTF and Horde | Nine, incl. Plant the Banner and Hold the Banner |

## Notes

Opcode 28 is arbitrary console execution behind a password, and multi-session turns one auth
surface into several concurrent ones. There is no connection cap or per-IP limit yet.

**Inebriate (opcodes 26 and 48) works on every DW map, with no chain swap.** In the base game
the drunk and blackout nodes live in a separate chain (`ChivPostProcess_drunk`) while the
default is `ChivPostProcess_noToneMap`, so most maps carry no drunk effect and AdminMod has to
swap the whole chain in -- which is why inebriate was long thought to be TO2-only there.
Deadliest Warrior put the nodes in the **default** chain instead: `CHV_PPC_Pack` ships only
`ChivPostProcess_noToneMap` and `ChivPostProcess_characterToScaleformRenderTarget`, both the
`DrunkEffect` and `blackout` effects are in the package, `DefaultPostProcessName`
(`CDWEngine.ini:140`) is noToneMap, and the Drunk sound mode is in `SoundClassesAndModes.upk`.
That is why the Pirate's flaming rum works out of the box.

So the swap machinery is inert here. It is kept as a fallback for a map that replaces the
chain with one lacking the nodes: set `AdminModDWDrunkChainPath` in
`AdminModDWPlayerController.uci` to a chain that has them and it is loaded by path at runtime,
no rebuild involved. Empty by default, because DW has no separate drunk chain to name.
`FPSpectateDebug` prints what resolved.

**Cooking on the DW SDK needs one config fix.** `[Engine.PackagesToAlwaysCook]` in
`CDWGame\Config\CDWEngine.ini` lists fourteen `TBSSeekFreePackage=DW_MUS_*` entries naming
uncooked source packages the retail install does not contain -- only the shipped `_SF`
variants exist. `CookPackages` dies on the first one with `Failed to find package
'DW_MUS_MainMenu'`, for any mod, before it finishes. Comment those fourteen lines out; the
section is cook-time only, so the game still loads its music normally. The base-game SDK has
no such entries, which is why AdminMod cooks there without this step.
