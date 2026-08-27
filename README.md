# SmartSkillup for Ashita v4

An Ashita-native port of RolandJ's Windower SmartSkillup addon. It builds a live
action catalog from the logged-in character and groups selectable actions into
Spells, Job abilities, and Weapon skills. Action names are not embedded in the
execution paths; the UI checklists decide which actions each mode may use.

## Install and load

The addon is already in `addons/smartskillup`. In game:

```text
/addon load smartskillup
```

The ImGui window lets you select individual available actions and start or pause
a session. Ambuscade uses separate checklists for setup buffs, Sleep, healing,
dispelling, combat buffs/debuffs, TP recovery, and weapon skills. The Sleep list
only shows available actions whose resource description identifies a Sleep
effect.

## Module layout

- `smartskillup.lua` owns settings, shared services, commands, and Ashita events.
- `action_catalog.lua` discovers available spells, job abilities, and weapon skills.
- `modes/skillup.lua` repeatedly executes checked actions for skill progression.
- `modes/afk.lua` detects and engages hostile actors that attack the player.
- `modes/ambuscade.lua` loads the selected fight from `ambuscades/registry.lua`.
- `ambuscades/plantoids_2026_08.lua` contains the current fight-specific tactics.
- `config_ui.lua` renders the configuration window and mode panels.

SmartSkillup has four execution modes:

- **Skill-up Rotation** repeatedly rotates checked available actions.
- **Command Rotation** executes an ordered list of user-provided commands and
  repeats from the beginning. Each entry can be individually enabled or disabled.
- **Ambuscade** loads the selected registered fight profile. The current profile
  is August 2026 Volume Two: Plantoids.
- **AFK Retaliation** enables `/autotarget` and attacks a live hostile actor only
  after an incoming action identifies that actor as attacking the player. Its
  panel has a separate persistent action checklist; while engaged, only those
  selected spells, job abilities, and weapon skills are rotated. Its optional
  automatic-pull section scans nearby hostile mobs, stores a selected mob name,
  and approaches the nearest live match for melee while the player is out of
  combat. When retaliation selects a new attacker, it checks
  Ashita's camera-lock state and only issues `/lockon` when lock-on is disabled,
  briefly drives Ashita's internal auto-follow state toward the attacker so the
  game performs the turn and emits its own movement packets, then stops movement
  before using `/attack` and retries until melee engagement is confirmed. The
  selected combat rotation does not begin until melee engagement is confirmed.
  While the player is not engaged, a detected attacker always replaces an
  unrelated current target before the engage sequence continues.
  Optional distant-attacker recovery uses auto-follow while measuring horizontal distance
  through Ashita's entity position getters. It stops near the configured melee
  distance or on engagement. A stalled or timed-out approach is stopped and
  retried up to three times. Movement is also stopped immediately when recovery
  is disabled, the mode is paused/stopped, the player dies/zones, or the tracked
  attacker becomes invalid. Direct attackers are remembered briefly, but only a
  substantially closer recent attacker can preempt a live target; a melee-confirmed
  target receives extra protection against rapid target thrashing. Targets
  that exhaust all approach attempts receive a temporary cooldown. Melee confirmation
  is tied to the selected target's server ID. When the player is no longer engaged and no direct attacker is
  tracked, the optional party-claim fallback adopts the current or nearest live
  mob claimed by a player or Trust in the party. It never adopts unclaimed mobs
  or mobs claimed by another party. Navmesh routing is attempted when a matching
  zone mesh is installed; direct auto-follow is the fallback.
  Combat uses the same role-based policy and settings as Ambuscade while target
  acquisition and movement remain AFK-specific. This includes emergency healing,
  recurring setup buffs, TP recovery, trust-synchronized weapon skills, combat
  buffs, and combat debuffs. The Terpander dummy-song procedure and three-song
  rotation are therefore identical in both modes. Automatic dispel remains
  fight-profile-specific because AFK mode does not track enemy enhancement text.
  Combat debuffs are tracked per target and per selected action; they are not
  reapplied until the configurable assumed effect duration expires.
  An opt-in combat packet recorder writes incoming and outgoing packet metadata
  plus complete raw hexadecimal payloads under
  `config/addons/smartskillup/logs/` for later behavior analysis. The same log
  records target adoption, measured distance, attack and follow commands,
  Ashita auto-run state, movement progress, retries, and stop reasons.

Additional Ambuscade fights should be implemented as separate files under
`ambuscades/` and registered in `ambuscades/registry.lua`; the core mode does not
need fight-specific changes.

## Ambuscade: August 2026 Plantoids

Summon your trusts and enter the battlefield manually, then press **Start**.
The profile uses the actions checked for each role. At the configured TP
threshold it uses a checked weapon skill, and below the configured HP threshold
it uses a checked healing action. On Normal and above it automatically targets
**Bozzetto Julika**, then **Bozzetto Jody**, and finally **Bozzetto Vivian**.
On Easy and Very Easy it targets Jody directly because the adds are absent.
Whenever **Bozzetto Golden Bomb** appears, it immediately takes priority over
the normal target order so the party can kill it for the 100-point bonus.
Golden Bomb detection bypasses normal song, spell, ability, and weaponskill
delays. The profile retargets it immediately and briefly retries `/attack <t>`
until the player and trusts have had an opportunity to transfer targets.
Vivian remains the final combat target so manual Sleep macros are not disrupted
while Julika or Jody is still active.
When a Sleep-capable action is checked, SmartSkillup briefly selects Vivian,
queues that action, and immediately restores the saved combat target through an
internal queued command. The routine never disengages, so trusts remain on the
combat target. Successful Sleep, resist/no-effect results, and wear-off messages
are tracked; retries are attempted when the action is ready without blocking buff
setup or other combat actions. Golden Bomb handling takes precedence over a new
Lullaby attempt.
Below the configured weapon-skill TP threshold it can use a checked TP-recovery
action before continuing the weapon-skill cycle.
The routine never sends `/attack off`; target changes do not deliberately
disengage the player or withdraw trusts.
Target acquisition and `/attack <t>` take priority over songs, spells, and job
abilities. When one target dies, the profile explicitly attacks the next target
before resuming buffs or other actions so trusts transfer immediately.
The window has checked-by-default controls for Julika, Vivian, and Jody. Uncheck
a mob when it dies to remove it immediately from targeting and spell steps; all
three controls reset to checked when a new routine starts.
The role sections have persistent checkboxes populated from spells, job
abilities, and weapon skills currently available to the logged-in character.
Unchecked actions cannot be issued by the refactored execution paths.
When Shantotto II is active, Bettyboom holds a checked weapon skill until the trust reaches
the configurable synchronization threshold (900 TP by default), improving the
chance that their actions form a skillchain and trigger a magic burst. If the
trust is absent, weaponskills proceed normally.
When Qultada is active and has 1000 TP or more, Bettyboom also holds the weapon skill
until Qultada spends TP and drops below 1000. This lets Qultada act first in the
weaponskill sequence. If Qultada is absent, this gate is ignored. Trust
synchronization is bounded to four seconds by default; when that timeout expires,
Bettyboom weaponskills instead of remaining TP-capped.
The Ambuscade panel shows the next planned action and up to five recently queued
commands; timeline entries disappear after 30 seconds. Recurring-buff duration defaults to
150 seconds for the current equipment, with a 15-second safety margin, so
checked setup buffs are refreshed every 135 seconds. Both values are
configurable in the Ambuscade panel. A checked dispel action is used only while
battle messages indicate that the current target has a removable enhancement.
The panel displays the number of known buffs on each enemy.
Action pacing uses each spell's resource cast time plus a small safety margin,
with short bounded delays for abilities and weapon skills. Nightingale songs use
an instant-cast delay. Matching player action-result packets release the wait
early, while interruption, recast, and insufficient-MP messages also wake the
rotation. State transitions such as engagement and movement retain their own
short fixed stabilization delays.
Queued actions are tracked as in-flight until they complete, fail, or reach a
bounded packet timeout. Initial and recurring song setup advances only after a
confirmed completion; failed or timed-out casts retain their position and retry
with backoff. Combat-debuff duration tracking likewise begins only after the
debuff action completes.

When **Use Terpander three-song rotation** is enabled, the shared combat script
automatically casts **Advancing March**, **Valor Minuet V**, **Army's Paeon**,
and an encounter-selected third song; these songs do not need to be selected as
setup buffs. The default third song is **Blade Madrigal**. During the Jody phase,
the rotation selects **Mage's Ballad III** when Apururu is at or below 55% MP or
Shantotto II is at or below 35% MP. The decision is frozen for the complete song
cycle so changing MP cannot alter an in-progress sequence. Army's Paeon is sung
with Terpander to establish a short dummy in the additional slot, then the
selected third real song overwrites the dummy using the normal potency instrument. The
resulting active songs are Advancing March, Valor Minuet V, and the selected
third song.
The dummy is used only during initial setup. Normal refresh cycles recast the
three real songs without casting Army's Paeon again.
On the initial Ambuscade setup only, the profile uses **Nightingale** followed by
**Troubadour** before starting the song sequence when those abilities are known
and ready. Recurring song refreshes do not spend these long recasts, and AFK
mode does not use them automatically.

After selecting and engaging each priority target, Ambuscade can automatically
approach it to the configured melee distance using Ashita's direct-follow
movement. Movement stops before the shared combat rotation runs and whenever
the target changes, disappears, the routine resets, or the addon stops. Trust
summoning, battlefield entry, and repeat entry remain manual.

## Commands

```text
/sms start
/sms stop
/sms pause
/sms resume
/sms toggle enhancing
/sms addskill enfeebling
/sms delskill enfeebling
/sms spells
/sms show
/sms hide
/sms help
```

`/smartskillup` and `/skillup` are aliases for `/sms`.

## Notes

- The addon only offers spells currently known and usable by the current
  main/sub job combination.
- Spells that allow self-targeting use `<me>`; other spells use `<t>`.
- Spells whose target flags include enemies are only cast while the player is
  engaged in combat. Support and self-targeted spells can still run while idle.
- **Friendly target** can be left at **None** to use the current target, or set
  to the player or an active member of the current party. Enemy spells always
  use the current combat target regardless of this selection.
- Set **MP cost limit** to zero to disable the per-spell MP cap.
- Set **Rest below MP%** to zero to disable automatic resting.
- The original Windower primitive UI was replaced by Ashita's ImGui UI.
- Auto-shutdown is intentionally not enabled by default in this port.
- Command Rotation executes commands exactly as entered and does not apply the
  spell mode's MP, target, recast, or combat rules. Macros should include any
  required targets, for example `/ma "Cure" <p1>` or `/ja "Provoke" <t>`.

## Original project

This is an Ashita-native port of Roland-J's SmartSkillup addon for Windower.
The original project is
[Roland-J/SmartSkillup](https://github.com/Roland-J/SmartSkillup).
