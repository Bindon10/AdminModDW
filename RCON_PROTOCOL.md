# AdminModDW — RCON protocol

**The wire format is identical to AdminMod's.** `AOCRCon.uc` is byte-for-byte the same file
in both SDKs, and `AOCRConPacket.uc` differs only in two parameter names, so the framing,
the opcode numbers, the payload field order and the auth handshake are unchanged. One
ChivRcon client talks to a base-game AdminMod server and a Deadliest Warrior AdminModDW
server without a build flag or a protocol version.

For the opcode table and payload layouts, see
`Development\Src\AdminMod\RCON_PROTOCOL.md` in the base-game SDK. Everything there applies
here except where this file says otherwise.

Every opcode 0–64 is implemented. Nothing was dropped in the port.

---

## Deadliest Warrior deltas

These are behaviour differences, not wire differences. No field moved, no opcode changed
number.

### 32 — SET_TEAM

Teams and classes are independent in Deadliest Warrior. The base game's swap has to walk
`AOCGRI.FamilyInfos` (0–4 Agatha, 5–9 Mason) and rebuild the class, because
`AOCGame.ChangeTeam` re-resolves the team from `CurrentFamilyInfo.FamilyFaction` and always
refuses. None of that exists here: `SetNewClass` takes the destination `TeamInfo`
explicitly, so the swap is one call — the same one `AOCGame.PerformDeathBasedAB`
(`AOCGame.uc:5398`) makes.

The player keeps their warrior class across the swap where the destination team allows it,
and is moved to the first allowed class where it does not. Team indices are the colour teams
(`EAOCFaction`: 0 Blue, 1 Red, then Green / Pink / White / Black), not Agatha/Mason.

In Team Objective the pawn is **not** killed to apply the switch: `AOCTeamObjectivePC.SetNewClass`
forwards `bNegPoints,,` and swallows `bForceSwitch`. The team change still lands.

**On FFA and Duel there is exactly one team, so there is nothing to move anyone to.** Both
force `NumTeams=1`, meaning `Teams[1]` and up are `None`. Opcode 32 refuses with
`SET_TEAM_FAILED ... there is no team 1 on this map; the only team here is 0 (…)`, and that
refusal is correct rather than a gap.

This differs from the base game, where the same command appears to work on an FFA map. It only
appears to: AdminMod never touches `Teams` at all — it changes the player's **faction** through
`AOCGRI.FamilyInfos` and `ServerChangeTeam`, and a faction still means something in Medieval
Warfare FFA. Deadliest Warrior has no equivalent, because its families are team-independent
and FFA turns team colour off outright (`AOCFFA.InitTeams` sets `bUseTeamColor = false`).

### 52 — SET_CLASS

`classIndex` is 0–5 into `AOCPawn.PlayerClasses`, in `EAOCClass` order:

| index | class |
|---|---|
| 0 | Samurai |
| 1 | Spartan |
| 2 | Viking |
| 3 | Knight |
| 4 | Ninja |
| 5 | Pirate |

Rejected with `SET_CLASS_FAILED` when the player's current team does not allow that class on
that map (`AOCTeamInfo.AllowedClasses`).

### 23 — PING_EXTENDED

Deadliest Warrior's `AOCPRI` has no `IdleTime` field; the base game added it later. The idle
seconds field keeps its position and its units, and is computed server-side from
`PlayerController.LastActiveTime` — the same value `AOCLTS.uc:413` uses to kick idlers.
It is a plain seconds count rather than the base game's byte-scaled value, so it does not
saturate at 1020 s.

### 30 — PLAYER_INFO

The class-name string is a Deadliest Warrior family — `CDWFamilyInfo_Samurai`,
`CDWFamilyInfo_Spartan`, `CDWFamilyInfo_Viking`, `CDWFamilyInfo_Knight`,
`CDWFamilyInfo_Ninja`, `CDWFamilyInfo_Pirate` — not an Agatha/Mason class.

### 7 — SAY_ALL_BIG

Deadliest Warrior has no `ClientShowLocalizedHeaderText`. The banner goes through
`ReceiveLocalizedHeaderText` (`AOCPlayerController.uc:3378`) instead, with a 6-second
display time and `bOverride=true` so an admin announcement jumps the header queue. Chat
still receives the line as well.

### 49 / 50 — SET_TOURNAMENT, READY_ALL

**Rebuilt, not ported — and rebuilt twice.** Deadliest Warrior has no tournament mode: no
`bTournamentMode`, no `TournamentTeamReadyThreshold`, no ready fields on `AOCGRI` or
`AOCPRI`, no `AdminReadyAll`, no `NotifyReady`, no `AdminTournamentMode` exec.

It also has **no readiness concept to borrow**, which the first attempt got wrong.
`AOCPlayerController.bReady` looks like one and is not: `SetReady(true)` fires on closing team
select or confirming a loadout (`AOCGFx_TeamSelection.uc:126`, `AOCView_Loadout.uc:936`) and
`SetReady(false)` fires on *opening* team select, character select or loadout
(`AOCBaseHUD.uc:2022/2038/2058`). It means "has picked a class and is not sitting in a menu" —
a join gate, which is exactly how vanilla `ShouldCountDown` uses it. A tournament gated on it
is satisfied the instant everyone spawns and un-satisfied again whenever somebody opens their
loadout, so it did nothing observable.

So the mod supplies its own:

- **Ready state is the mod's**, an array of Steam IDs on the RCON actor
  (`AdminModDWReadyIds`). Steam ID rather than a PRI pointer, so a reconnect mid-pre-round
  does not keep a stale ready.
- **Players ready up with `!ready`** (or `!r`), and clear with `!unready` / `!notready`.
  `AdminModDWGame.BroadcastMessage` already sees every chat line, so the command is
  intercepted and consumed rather than echoed as conversation. It is handled *before* the
  mute check: readying up is a game action, not talking, so a text-muted player may still do
  it.
- **`AdminModDWGame.ShouldCountDown` gates on that list.** Every populated team must clear
  `thresholdPercent` — stricter than vanilla's "any two teams have somebody ready", because a
  round starting while one side is still picking loadouts is the thing this exists to prevent.
  A one-sided match is also held, except on modes that only have one team (FFA, Duel), which
  would otherwise wait forever.
- **Feedback is chat only.** DW has no ready UI and nothing on its GRI or PRI to replicate a
  ready flag through, so a scoreboard tick would mean shipping a HUD. Each ready/unready is
  announced with running progress ("Bindon is ready (3/6 ready)"), and a throttled "waiting
  on N more" line goes out every 15 s while the round is held — the pre-round asks
  `ShouldCountDown` once a second, so that nag needs the throttle.
- **Readiness is per round.** `StartRound` wipes it, and so does toggling opcode 49 either
  way.

`READY_ALL` with `ready=1` marks everyone ready and latches `bAdminModDWForcedReady`, so a
player joining mid-countdown cannot pull the round back into waiting — but anyone typing
`!unready` drops the latch, or the announcement would be a lie. `ready=0` clears everything.

Enabling also sets `bDisableAutoBalance`, clears `AOCGRI.bBalanceTeams` and
`bUseMaxPingLimit`, and sets `bAdminCanPause` and `bAnyUserCanGetSteamID`. Those are not
reverted on disable — we cannot know what the server had before.

Two differences from the base game's version worth knowing: it is **not one-shot** (the base
game's `StartRound` clears `bTournamentMode`; this gates every round until an admin turns it
off), and it is **runtime-only** — nothing is written to the ini, so a server restart clears
it.

### 45 — SET_AUTOBALANCE

`AOCGRI.bBalanceTeams` is only what the HUD draws. The gate that actually stops a swap is
`AOCGame.bDisableAutoBalance`, the first line of `PerformDeathBasedAB`. Both are set.

### 34 — SET_TEAM_SCORE

Unchanged in behaviour, including the LTS warning: `AOCLTS.uc:309` tests
`RoundScores[winner] == GoalScore` **after** incrementing, so a team parked exactly on the
goal steps over it and the match never ends. Set `GoalScore - 1` if the next round should
decide it. `AOCLTSGRI.RoundsWon` is a fixed-size array indexed by `EAOCFaction` in this SDK
rather than a dynamic one, so it is bounds-checked against `RoundScores`.

### 26 / 48 — INEBRIATE, SOBER

**These work on every DW map, unlike the base game.** `AOCBaseHUD` looks the effects up by
name (`'drunkeffect'`, `'blackout'`, `AOCBaseHUD.uc:1351`) exactly as the base game does, but
where the two differ is which chain carries them.

Medieval Warfare keeps the drunk and blackout nodes in a sibling chain,
`ChivPostProcess_drunk`, while the default is `ChivPostProcess_noToneMap` — so most maps have
no drunk effect and AdminMod swaps the whole chain in. Deadliest Warrior put the nodes in the
**default** chain: `CHV_PPC_Pack` contains exactly two chains, `ChivPostProcess_noToneMap` and
`ChivPostProcess_characterToScaleformRenderTarget`, and carries `DrunkEffect` and `blackout`;
`DefaultPostProcessName` (`CDWEngine.ini:140`) is noToneMap; the Drunk sound mode is in
`SoundClassesAndModes.upk`. That is why the Pirate's flaming rum inebriates with no chain
swap, and it is why opcode 26 needs none either.

The swap machinery is therefore inert on stock DW and kept only as a fallback for a map that
replaces the chain with one lacking the nodes. `AdminModDWDrunkChainPath` in
`AdminModDWPlayerController.uci` is empty by default — DW has no separate drunk chain to name
— and a chain set there is loaded by path at runtime, no rebuild involved.

---

### 44 — END_MATCH

Deadliest Warrior's `AOCFFA.EndGame` gates its whole body on `Reason ~= "TimeLimit"`. Medieval Warfare's
copy also accepts `"Admin action"`; DW's does not. Any other string is a silent no-op — the packet is
handled, the audit fires, and the match never ends. So the handler passes `"TimeLimit"` in both games.
Every base `AOCGame` mode ignores Reason beyond `EndLogging`, so nothing is lost.

`winningTeam` does not choose the winner: `EndGame` opens with `WinningTeam = GetWinningTeam()`, read off
the live scores. The parameter only picks whose top scorer is spotlighted. Set the scores with opcode 34
first if a specific team has to win.

---

### 62 / 63 / 64 — MUTE_LIST_REQUEST, MUTE_INFO, MUTE_LIST_END

`MUTE_INFO` gained a trailing `int stored`. 0 marks a live mute the mod never recorded:
`AOCPlayerController.AdminMutePlayer` (Medieval Warfare calls it `ServerAdminMutePlayer`) writes
`AOCPRI.bIsAdminMuted` straight and never touches the stored list, so it is a real mute that lasts only
until that player disconnects. A client that stops reading after `online` treats everything as stored,
which is what a pre-1.4 server meant.

---

### 39 / 40 / 41 — BAN_LIST_REQUEST, BAN_INFO, BAN_LIST_END

No DW delta in the wire format, but the handler was widened in both games at the same time and
the reason applies identically here. Chivalry enforces **three** ban stores and the mod used to
report only the first:

- `AOCAccessControl.Bans` — rich entries (name, reason, duration, IP policy). Written by
  `AddBan`/`KickBanGlobal`, i.e. the RCON ban, votekick and the ping kick.
- `Engine.AccessControl.BannedIDs` — bare uids, written by the console `admin kickban`.
  `AOCAccessControl.IsIDBanned` ends with `return bBanned || Super.IsIDBanned(NetID)`
  (`AOCAccessControl.uc:242` in the CDW tree), so these are live bans. Sent as
  `(uid ban list)`, duration 0, because the game stores nothing else about them.
- `Engine.AccessControl.IPPolicies` — `DENY,<ip>` lines, live through
  `Super.CheckIPPolicy`. Sent with uid 0 and name `(ip ban)`; they cannot be lifted by uid,
  they have to come out of the ini.

`KickBanPlayer` appends the DENY line and the `BannedIDs` entry in the same call, so when the two arrays
pair one-for-one the Nth policy rides on the Nth uid's row instead of becoming a separate entry. The address
is empty in practice — a Steam socket address has no `:port`, so `Left(IP, InStr(IP, ":"))` returns "" — and
a bare `DENY,` matches no address in `CheckIPPolicy`, so it is never listed as a ban.

Entries already covered by `Bans` are not repeated, and `BAN_LIST_END` counts everything sent.
Opcode 20 (UNBAN_PLAYER) now also removes from `BannedIDs` — and its paired DENY line — since `UnbanByUID`
only touches `Bans` and an entry shown as `(uid ban list)` would otherwise never actually lift.

---

## Gametypes and map prefixes

Claimed in `DefaultAdminModDW.ini`, taken from each DW gametype's own `MapPrefixes` default:

Deadliest Warrior registers **two** prefixes per mode -- the inherited `AOC*` form and a
short form -- and its own maps use the short one. Both are claimed; the stock table they
mirror is `DefaultMapPrefixes` in `CDWGame\Config\CDWGame.ini` and `PCServer-CDWGame.ini`.

| prefixes | vanilla class | AdminModDW class |
|---|---|---|
| `AOCTD`, `TD` | `AOCTD` | `AdminModDWTD` (DefaultGame) |
| `AOCTO`, `TO` | `AOCTeamObjective` | `AdminModDWTO` |
| `AOCFFA`, `FFA` | `AOCFFA` | `AdminModDWFFA` |
| `AOCLTS`, `LTS` | `AOCLTS` | `AdminModDWLTS` |
| `AOCKOTH`, `KOTH` | `AOCKOTH` | `AdminModDWKOTH` |
| `AOCTUT`, `TUT` | `AOCTUT` | `AdminModDWTUT` |
| `DUEL` | `CDWDuel` | `AdminModDWDuel` |
| `AOCDUEL` | — (dead entry) | `AdminModDWDuel` |
| `PTB` | `CDWPlantTheBanner` | `AdminModDWPTB` |
| `HTB` | `CDWHoldTheBanner` | `AdminModDWHTB` |

Not claimed: `AOC` (the frontend/entry map, `CDW.AOCEntry`); `CTF` / `AOCCTF`, `SURV` /
`AOCSURV`, `CTL` / `AOCCTL`, which vanilla registers against classes that do not exist in
this SDK; and `MOV` / `AOCMOV`, which has no maps.

`AOCDUEL` is claimed even though no DW gametype declares it, because vanilla
`AOCGame.SetGameType` (`AOCGame.uc:3791`) injects that prefix at runtime pointing at
`"CDW.AOCDUEL"` — a class that does not exist in this SDK — and `StaticSaveConfig` persists
it, where it can be read at `PCServer-CDWGame.ini:1511`. Our override runs first, so claiming
it fixes that dead lookup as a side effect.

`TO2` is absent because Horde is a Medieval Warfare mode: `CMWTO2` does not exist here.
