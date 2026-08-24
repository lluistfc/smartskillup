# SmartSkillup navigation proof of concept

The optional AFK recovery pathfinder uses `runtime/FFXINAV.dll` version 1.0.1.5
and a zone-specific Recast/Detour mesh. It is enabled by the **Use navmesh
pathfinding** setting and falls back to direct Ashita auto-follow when the native
runtime or current-zone mesh is unavailable.

Currently bundled mesh:

- `runtime/288.nav`: Escha - Zi'Tah

Sources and licenses:

- FFXINAV runtime: <https://github.com/LandSandBoat/FFXI-NavMesh-Builder>
  (documented MD5 `fd877064d9387db812252cceac14c691`)
- Zone mesh: <https://github.com/LandSandBoat/xiNavmeshes> (GPL-2.0)

The addon never injects movement packets. Waypoints are written to Ashita's
auto-follow deltas so FFXI remains responsible for movement and packet output.
