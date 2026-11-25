"""A 48K Spectrum on the host: loads the tape through the real ROM, then runs it
one frame at a time with simulated keys. Built on SkoolKit's Z80 simulator."""

import subprocess
import sys
from pathlib import Path

from skoolkit.simulator import Simulator
from skoolkit.simutils import (B, C, FRAME_DURATIONS, H, HALT, IFF, IM,
                               INT_ACTIVE, IYh, IYl, L, PC, SP, T, from_snapshot,
                               xH, xL)
from skoolkit.snapshot import Snapshot

BUILD_DIR = Path(__file__).resolve().parent.parent / "build"
TAP = BUILD_DIR / "smiley.tap"
TZX = BUILD_DIR / "smiley.tzx"
SYMBOLS = BUILD_DIR / "smiley.sym"
SCRIPTS_DIR = Path(sys.executable).parent

CODE_START = 0x8000
FRAME_TSTATES = FRAME_DURATIONS[0]
INTERRUPT_TSTATES = INT_ACTIVE[0]
ROM_STACK_BC = 0x2D2B  # USR's return address: the ROM puts BC on the calculator stack

ROWS = 24
COLUMNS = 32
CELL_LINES = 8
PIXELS_START = 0x4000
ATTRIBUTES_START = 0x5800

# (half-row address line, bit) for each key the tests press.
KEYS = {
    "CAPS SHIFT": (0, 0), "Z": (0, 1), "X": (0, 2), "C": (0, 3), "V": (0, 4),
    "P": (5, 0), "O": (5, 1), "I": (5, 2), "U": (5, 3), "Y": (5, 4),
    "ENTER": (6, 0), "L": (6, 1), "K": (6, 2), "J": (6, 3), "H": (6, 4),
    "SPACE": (7, 0), "SYMBOL SHIFT": (7, 1),
}


def run_script(name, *arguments):
    result = subprocess.run([SCRIPTS_DIR / name, *map(str, arguments)],
                            capture_output=True, text=True, check=True)
    return result.stdout


def load_tape(tape, snapshot_path):
    """LOAD "" the tape using the 48K ROM; stop when the code is entered."""
    run_script("tap2sna.py", "--start", CODE_START, tape, snapshot_path)
    return Snapshot.get(str(snapshot_path))


def symbols():
    table = {}
    for line in SYMBOLS.read_text().splitlines():
        name, _, value = line.split()
        table[name] = int(value.rstrip("H"), 16)
    return table


def expected_pixel_address(row, column, line=0):
    third, row_in_third = divmod(row, 8)
    return PIXELS_START + third * 2048 + line * 256 + row_in_third * 32 + column


def expected_attribute_address(row, column):
    return ATTRIBUTES_START + row * COLUMNS + column


class Spectrum:
    def __init__(self, snapshot):
        self.simulator = from_snapshot(Simulator, snapshot)
        self.memory = self.simulator.memory
        self.registers = self.simulator.registers
        self.simulator.set_tracer(self)
        self.keys = set()
        self.border = snapshot.border
        # Sample mid-frame: the program's work straight after HALT is done by then.
        self.deadline = (self.registers[T] // FRAME_TSTATES) * FRAME_TSTATES + FRAME_TSTATES // 2
        self.entry_stack_pointer = self.registers[SP]

    # Called by the simulator on IN and OUT.
    def read_port(self, registers, port):
        value = 0xFF
        if port & 1 == 0:
            for half_row, bit in (KEYS[key] for key in self.keys):
                if port & (0x100 << half_row) == 0:
                    value &= ~(1 << bit)
        return value

    def write_port(self, registers, port, value, offset):
        if port & 1 == 0:
            self.border = value & 7

    def step(self):
        pc = self.registers[PC]
        self.simulator.opcodes[self.memory[pc]]()
        interrupt_active = self.registers[T] % FRAME_TSTATES < INTERRUPT_TSTATES
        if interrupt_active and self.registers[IFF]:
            self.simulator.accept_interrupt(self.registers, self.memory, pc)

    def run_frames(self, count):
        self.deadline += count * FRAME_TSTATES
        while self.registers[T] < self.deadline:
            self.step()

    def returns_to_basic_within(self, frames):
        limit = self.registers[T] + frames * FRAME_TSTATES
        while self.registers[T] < limit:
            self.step()
            if self.registers[PC] == ROM_STACK_BC:
                return True
        return False

    def call_with_cell(self, address, row, column):
        """Call a routine with B=row, C=column; return HL."""
        self.registers[B], self.registers[C] = row, column
        self.registers[PC] = address
        while self.registers[PC] != ROM_STACK_BC:
            self.simulator.opcodes[self.memory[self.registers[PC]]]()
        return self.pair(H, L)

    def enter(self, address):
        """Start the program again, as RANDOMIZE USR would."""
        self.registers[SP] = self.entry_stack_pointer
        self.memory[self.registers[SP]] = ROM_STACK_BC & 0xFF
        self.memory[self.registers[SP] + 1] = ROM_STACK_BC >> 8
        self.registers[PC] = address
        self.registers[HALT] = 0
        self.deadline = (self.registers[T] // FRAME_TSTATES) * FRAME_TSTATES + FRAME_TSTATES // 2

    def pair(self, high, low):
        return self.registers[high] * 256 + self.registers[low]

    @property
    def iy(self):
        return self.pair(IYh, IYl)

    @property
    def alternate_hl(self):
        return self.pair(xH, xL)

    @property
    def stack_pointer(self):
        return self.registers[SP]

    @property
    def interrupts_enabled(self):
        return bool(self.registers[IFF])

    @property
    def interrupt_mode(self):
        return self.registers[IM]

    def cell(self, row, column):
        """(8 pixel bytes, attribute) of one character cell."""
        pixels = tuple(self.memory[expected_pixel_address(row, column, line)]
                       for line in range(CELL_LINES))
        return pixels, self.memory[expected_attribute_address(row, column)]
