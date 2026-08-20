# SmartSkillup for Ashita v4

An Ashita-native port of RolandJ's Windower SmartSkillup addon. It discovers
spells from Ashita's resource and player managers, rotates among selected magic
skills, observes spell recasts and available MP, and rests automatically.

## Install and load

The addon is already in `addons/smartskillup`. In game:

```text
/addon load smartskillup
```

The ImGui window lets you select skills and start or pause a session.

SmartSkillup has three execution modes:

- **Spell Rotation** discovers and rotates usable spells for the selected skills.
- **Command Rotation** executes an ordered list of user-provided commands and
  repeats from the beginning. Each entry can be individually enabled or disabled.
- **Ambuscade: Plantoids (BRD/DNC)** runs an August 2026 Volume Two combat profile
  for Bettyboom's BRD/DNC and configured trust party.

## Ambuscade: Plantoids (BRD/DNC)

Summon your trusts and enter the battlefield manually, then press **Start**.
The profile casts Advancing March and Valor Minuet V; engages; maintains Haste
Samba and Box Step; uses Viper Bite at 1000 TP; and uses Curing Waltz III below
the configured HP threshold. On Normal and above it automatically targets
**Bozzetto Julika**, then **Bozzetto Jody**, and finally **Bozzetto Vivian**.
On Easy and Very Easy it targets Jody directly because the adds are absent.
The profile sleeps Vivian with Foe Lullaby II and refreshes it every 50 seconds
while either Julika or Jody remains active. Vivian becomes the combat target only
after both preceding enemies are defeated or unchecked.
At exactly five Finishing Moves and below 1000 TP, it uses Reverse Flourish to
convert the moves into TP before continuing the weaponskill cycle.
The routine never sends `/attack off`; Lullaby refreshes and target changes do
not deliberately disengage the player or withdraw trusts.
The window has checked-by-default controls for Julika, Vivian, and Jody. Uncheck
a mob when it dies to remove it immediately from targeting and spell steps; all
three controls reset to checked when a new routine starts.
The Skill permissions section has persistent checkboxes for every action the
profile can issue. Disabled songs, spells, job abilities, and the configured
weaponskill are skipped in setup, maintenance, retry, and combat paths.
When Shantotto II is active, Bettyboom holds Viper Bite until the trust reaches
the configurable synchronization threshold (900 TP by default), improving the
chance that their actions form a skillchain and trigger a magic burst. If the
trust is absent, weaponskills proceed normally.
When Qultada is active and has 1000 TP or more, Bettyboom also holds Viper Bite
until Qultada spends TP and drops below 1000. This lets Qultada act first in the
weaponskill sequence. If Qultada is absent, this gate is ignored. Trust
synchronization is bounded to four seconds by default; when that timeout expires,
Bettyboom weaponskills instead of remaining TP-capped.
Song commands are verified against Bettyboom's active March and Minuet effects.
The routine records a song as confirmed only after its buff appears and retries
an unconfirmed cast twice before continuing.
The Ambuscade panel shows the next planned action and up to five recently queued
commands; timeline entries disappear after 30 seconds. Advancing March and Valor Minuet V are refreshed
every 110 seconds. Magic Finale is used on the current combat target every 30
seconds only while battle messages indicate that target has a removable
enhancement. The panel displays the number of known buffs on each enemy.

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
