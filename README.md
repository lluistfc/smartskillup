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

- `smartskillup.lua` owns settings, mode lifecycle, commands, and Ashita events.
- `action_catalog.lua` discovers available spells, job abilities, and weapon skills.
- `ambuscade.lua` owns fight targeting, role execution, timers, and combat-log tracking.
- `config_ui.lua` renders the configuration window and action checklists.

SmartSkillup has three execution modes:

- **Spell Rotation** discovers and rotates usable spells for the selected skills.
- **Command Rotation** executes an ordered list of user-provided commands and
  repeats from the beginning. Each entry can be individually enabled or disabled.
- **Ambuscade: Plantoids (BRD/DNC)** runs an August 2026 Volume Two combat profile
  for Bettyboom's BRD/DNC and configured trust party.

## Ambuscade: Plantoids (BRD/DNC)

Summon your trusts and enter the battlefield manually, then press **Start**.
The profile uses the actions checked for each role. At the configured TP
threshold it uses a checked weapon skill, and below the configured HP threshold
it uses a checked healing action. On Normal and above it automatically targets
**Bozzetto Julika**, then **Bozzetto Jody**, and finally **Bozzetto Vivian**.
On Easy and Very Easy it targets Jody directly because the adds are absent.
Whenever **Bozzetto Golden Bomb** appears, it immediately takes priority over
the normal target order so the party can kill it for the 100-point bonus.
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

Trust summoning, battlefield entry, movement, and repeat entry are intentionally manual.

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
