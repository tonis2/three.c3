// The fixture `a_game_boots_from_many_files` boots: one import per shape a
// game actually writes — a relative sibling directory, and a rooted path that
// must mean the same module (the same instance, not a second evaluation).
import { GRID } from './parts/grid.js';
import size from '/parts/size.js';

console.log(`grid: ${GRID.length}`);
globalThis.__game = { grid: GRID.length, size };
