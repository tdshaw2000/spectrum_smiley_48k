import tempfile
import unittest
from pathlib import Path

import spectrum
from spectrum import COLUMNS, ROWS, Spectrum

SMILEY = (0x3C, 0x42, 0xA5, 0x81, 0xA5, 0x99, 0x42, 0x3C)
SMILEY_ATTRIBUTE = 0x46
BLANK_CELL = ((0,) * 8, 0x07)
SMILEY_CELL = (SMILEY, SMILEY_ATTRIBUTE)
START_CELL = (10, 15)
BLACK = 0
SETTLE_FRAMES = 10
MORE_TAPS_THAN_CELLS = 40
BASIC_IY = 0x5C3A
BASIC_ALTERNATE_HL = 0x2758


def setUpModule():
    global snapshot, symbol_table
    with tempfile.TemporaryDirectory() as directory:
        snapshot = spectrum.load_tape(spectrum.TAP, Path(directory) / "smiley.z80")
    symbol_table = spectrum.symbols()


class ProgramTest(unittest.TestCase):
    def setUp(self):
        self.machine = Spectrum(snapshot)
        self.machine.run_frames(SETTLE_FRAMES)

    def assert_only_smiley_at(self, row, column):
        wrong = []
        for cell in ((r, c) for r in range(ROWS) for c in range(COLUMNS)):
            expected = SMILEY_CELL if cell == (row, column) else BLANK_CELL
            if self.machine.cell(*cell) != expected:
                wrong.append(cell)
        if wrong:
            pixels, attribute = self.machine.cell(*wrong[0])
            self.fail(f"smiley should be only at {(row, column)}; {len(wrong)} wrong cell(s), "
                      f"first {wrong[0]}: pixels {bytes(pixels).hex()} attribute ${attribute:02X}")

    def hold(self, *keys):
        self.machine.keys = set(keys)

    def tap(self, *keys):
        self.hold(*keys)
        self.machine.run_frames(1)
        self.hold()
        self.machine.run_frames(1)

    def tap_repeatedly(self, key, times):
        for _ in range(times):
            self.tap(key)


class AddressTest(unittest.TestCase):
    CELLS = [(0, 0), (0, 31), (7, 0), (8, 0), (10, 15), (15, 31), (16, 0), (23, 31)]

    def assert_addresses(self, routine, expected_address):
        for row, column in self.CELLS:
            with self.subTest(row=row, column=column):
                actual = Spectrum(snapshot).call_with_cell(symbol_table[routine], row, column)
                self.assertEqual(f"${expected_address(row, column):04X}", f"${actual:04X}")

    def test_pixel_addresses(self):
        self.assert_addresses("cell_pixel_address", spectrum.expected_pixel_address)

    def test_attribute_addresses(self):
        self.assert_addresses("cell_attribute_address", spectrum.expected_attribute_address)

    def test_expected_addresses_match_hand_calculation(self):
        self.assertEqual(0x484F, spectrum.expected_pixel_address(10, 15))
        self.assertEqual(0x50FF, spectrum.expected_pixel_address(23, 31))
        self.assertEqual(0x594F, spectrum.expected_attribute_address(10, 15))
        self.assertEqual(0x5AFF, spectrum.expected_attribute_address(23, 31))


class StartupTest(ProgramTest):
    def test_screen_is_clear_except_for_smiley_in_the_middle(self):
        self.assert_only_smiley_at(*START_CELL)

    def test_border_is_black(self):
        self.assertEqual(BLACK, self.machine.border)


class MovementTest(ProgramTest):
    def test_each_key_moves_one_cell(self):
        for key, row, column in (("Z", 10, 14), ("X", 10, 16), ("O", 9, 15), ("K", 11, 15)):
            with self.subTest(key=key):
                self.setUp()
                self.tap(key)
                self.assert_only_smiley_at(row, column)

    def test_other_keys_in_the_same_half_rows_do_nothing(self):
        for key in ("CAPS SHIFT", "C", "V", "P", "I", "U", "Y", "ENTER", "L", "J", "H"):
            with self.subTest(key=key):
                self.setUp()
                self.tap(key)
                self.assert_only_smiley_at(*START_CELL)

    def test_every_cell_on_the_way_down_is_erased(self):
        for row in range(START_CELL[0] + 1, ROWS):
            self.tap("K")
            self.assert_only_smiley_at(row, START_CELL[1])

    def test_one_direction_per_move_in_priority_order(self):
        for keys, row, column in ((("Z", "X", "O", "K"), 10, 14), (("X", "O", "K"), 10, 16),
                                  (("O", "K"), 9, 15)):
            with self.subTest(keys=keys):
                self.setUp()
                self.tap(*keys)
                self.assert_only_smiley_at(row, column)

    def test_stops_at_each_edge(self):
        for key, row, column in (("Z", 10, 0), ("X", 10, 31), ("O", 0, 15), ("K", 23, 15)):
            with self.subTest(key=key):
                self.setUp()
                self.tap_repeatedly(key, MORE_TAPS_THAN_CELLS)
                self.assert_only_smiley_at(row, column)

    def test_stops_in_opposite_corners(self):
        for horizontal, vertical, row, column in (("Z", "O", 0, 0), ("X", "K", 23, 31)):
            with self.subTest(row=row, column=column):
                self.setUp()
                self.tap_repeatedly(horizontal, MORE_TAPS_THAN_CELLS)
                self.tap_repeatedly(vertical, MORE_TAPS_THAN_CELLS)
                self.assert_only_smiley_at(row, column)


class RepeatTest(ProgramTest):
    def test_held_key_moves_on_the_first_frame_then_every_sixth(self):
        self.hold("X")
        for frame in range(1, 21):
            self.machine.run_frames(1)
            moves = (frame - 1) // 6 + 1
            with self.subTest(frame=frame):
                self.assert_only_smiley_at(START_CELL[0], START_CELL[1] + moves)

    def test_releasing_and_pressing_again_moves_at_once(self):
        self.tap("X")
        self.tap("X")
        self.assert_only_smiley_at(START_CELL[0], START_CELL[1] + 2)


class BreakTest(ProgramTest):
    def test_break_returns_to_basic_with_its_registers_intact(self):
        self.hold("CAPS SHIFT", "SPACE")
        self.assertTrue(self.machine.returns_to_basic_within(frames=2), "BREAK was ignored")
        self.assertEqual(self.machine.entry_stack_pointer + 2, self.machine.stack_pointer)
        self.assertEqual(BASIC_IY, self.machine.iy)
        self.assertEqual(BASIC_ALTERNATE_HL, self.machine.alternate_hl)
        self.assertEqual(1, self.machine.interrupt_mode)
        self.assertTrue(self.machine.interrupts_enabled)

    def test_break_works_while_a_movement_key_is_held(self):
        self.hold("X")
        self.machine.run_frames(3)
        self.hold("X", "CAPS SHIFT", "SPACE")
        self.assertTrue(self.machine.returns_to_basic_within(frames=2), "BREAK was ignored")

    def test_half_of_break_does_not_exit(self):
        for key in ("CAPS SHIFT", "SPACE"):
            with self.subTest(key=key):
                self.setUp()
                self.hold(key)
                self.assertFalse(self.machine.returns_to_basic_within(frames=3))
                self.assert_only_smiley_at(*START_CELL)

    def test_caps_shift_does_not_stop_movement(self):
        self.tap("CAPS SHIFT", "Z")
        self.assert_only_smiley_at(10, 14)

    def test_running_again_after_break_starts_afresh(self):
        self.tap("X")
        self.hold("CAPS SHIFT", "SPACE")
        self.assertTrue(self.machine.returns_to_basic_within(frames=2), "BREAK was ignored")
        self.hold()
        self.machine.enter(symbol_table["start"])
        self.machine.run_frames(SETTLE_FRAMES)
        self.assert_only_smiley_at(*START_CELL)


class TapeTest(unittest.TestCase):
    BASIC_PROGRAM = 0
    CODE = 3
    HEADER_FLAG = 0x00
    DATA_FLAG = 0xFF

    def blocks(self):
        data = spectrum.TAP.read_bytes()
        while data:
            length = int.from_bytes(data[:2], "little")
            yield data[2:2 + length]
            data = data[2 + length:]

    def test_tap_is_a_basic_header_and_data_then_a_code_header_and_data(self):
        basic_header, basic, code_header, code = self.blocks()
        self.assertEqual((self.HEADER_FLAG, self.BASIC_PROGRAM), tuple(basic_header[:2]))
        self.assertEqual((self.HEADER_FLAG, self.CODE), tuple(code_header[:2]))
        self.assertEqual((self.DATA_FLAG, self.DATA_FLAG), (basic[0], code[0]))
        self.assertEqual(b"smiley    ", code_header[2:12])
        self.assertEqual(spectrum.CODE_START, int.from_bytes(code_header[14:16], "little"))
        self.assertEqual(len(code) - 2, int.from_bytes(code_header[12:14], "little"))

    def test_every_block_checksum_is_valid(self):
        for number, block in enumerate(self.blocks(), start=1):
            with self.subTest(block=number):
                parity = 0
                for byte in block:
                    parity ^= byte
                self.assertEqual(0, parity)

    def test_basic_loader_autostarts_and_loads_and_runs_the_code(self):
        basic_header = next(self.blocks())
        self.assertEqual(10, int.from_bytes(basic_header[14:16], "little"))
        listing = spectrum.run_script("tapinfo.py", "-b", 2, spectrum.TAP)
        for statement in ("CLEAR 32767", 'LOAD ""CODE', "RANDOMIZE USR 32768"):
            self.assertIn(statement, listing)

    def test_tzx_loads_through_the_rom_too(self):
        self.assertTrue(spectrum.TZX.read_bytes().startswith(b"ZXTape!\x1a"))
        with tempfile.TemporaryDirectory() as directory:
            loaded = spectrum.load_tape(spectrum.TZX, Path(directory) / "smiley.z80")
        self.assertEqual(spectrum.CODE_START, loaded.pc)


if __name__ == "__main__":
    unittest.main()
