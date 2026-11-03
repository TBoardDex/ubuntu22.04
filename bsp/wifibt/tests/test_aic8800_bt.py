#!/usr/bin/env python3
"""Protocol checks with a simulated controller; never open a board UART."""
import importlib.machinery
import importlib.util
from pathlib import Path
import socket
import struct
import threading
import os
import pty
import termios
import unittest
from unittest import mock


loader = importlib.machinery.SourceFileLoader(
    "aic_bt", str(Path(__file__).resolve().parents[1] / "scripts/aic8800-bt-attach"))
spec = importlib.util.spec_from_loader(loader.name, loader)
bt = importlib.util.module_from_spec(spec)
loader.exec_module(bt)


def complete(opcode, status=0, data=b""):
    payload = b"\x01" + struct.pack("<H", opcode) + bytes([status]) + data
    return b"\x04\x0e" + bytes([len(payload)]) + payload


class H4Tests(unittest.TestCase):
    def setUp(self):
        self.host, self.controller = socket.socketpair()
        self.host.setblocking(False)
        self.addCleanup(self.host.close)
        self.addCleanup(self.controller.close)
        self.hci = bt.H4(self.host.fileno(), 0.1)

    def test_fragmented_response_and_unrelated_packets(self):
        # An ACL frame, asynchronous vendor event and another command's
        # completion must not be mistaken for the requested response.
        self.controller.sendall(b"\x02\x01\x00\x02\x00xy\x04\xff\x01z" +
                                complete(0x1009, data=b"abc"))
        frame = complete(0x0c03)

        def respond():
            self.controller.recv(4096)
            for byte in frame:
                self.controller.sendall(bytes([byte]))

        thread = threading.Thread(target=respond)
        thread.start()
        try:
            self.assertEqual(self.hci.command(0x0c03), b"")
        finally:
            thread.join(timeout=1)
        self.assertFalse(thread.is_alive())

    def test_command_complete_failure(self):
        self.controller.sendall(complete(0xfc72, status=1))
        with self.assertRaisesRegex(OSError, "0xfc72.*0x01"):
            self.hci.command(0xfc72, bt.PTA_CONFIG)

    def test_command_status_failure(self):
        self.controller.sendall(b"\x04\x0f\x04\x0c\x01\x03\x0c")
        with self.assertRaisesRegex(OSError, "rejected"):
            self.hci.command(0x0c03)

    def test_timeout_is_failure(self):
        with self.assertRaises(TimeoutError):
            self.hci.command(0x0c03)

    def test_bad_uart_framing_is_failure(self):
        self.controller.sendall(b"\xff")
        with self.assertRaisesRegex(OSError, "Invalid H4"):
            self.hci.command(0x0c03)

    def test_success_status_waits_for_complete(self):
        self.controller.sendall(b"\x04\x0f\x04\x00\x01\x03\x0c" + complete(0x0c03))
        self.assertEqual(self.hci.command(0x0c03), b"")


class InitializationTests(unittest.TestCase):
    def test_uart_raw_mode_and_flow_control_on_pty(self):
        master, slave = pty.openpty()
        try:
            fd = bt.open_uart(os.ttyname(slave), 1500000)
            try:
                attrs = termios.tcgetattr(fd)
                self.assertEqual(attrs[0], 0)
                self.assertEqual(attrs[1], 0)
                self.assertEqual(attrs[3], 0)
                self.assertTrue(attrs[2] & termios.CRTSCTS)
                self.assertEqual(attrs[4:6], [termios.B1500000] * 2)
            finally:
                os.close(fd)
        finally:
            os.close(slave)
            os.close(master)

    def controller(self, current=bytes.fromhex("665544332202")):
        def response(opcode, payload=b""):
            if opcode == 0x1001:
                return bytes(8)
            if opcode == 0x1009:
                return current
            return b""
        hci = mock.Mock()
        hci.command.side_effect = response
        return hci

    def test_valid_address_preserved_and_pta_applied(self):
        hci = self.controller()
        bt.initialize(hci)
        self.assertEqual(hci.command.call_args_list, [mock.call(0x0c03), mock.call(0x1001),
                         mock.call(0x1009), mock.call(0xfc72, bt.PTA_CONFIG)])

    def test_null_address_replaced_with_unique_board_address(self):
        hci = self.controller(bytes(6))
        with mock.patch.object(bt, "stable_address", return_value=bytes.fromhex("02aabbccddee")):
            bt.initialize(hci)
        self.assertIn(mock.call(0xfc70, bytes.fromhex("eeddccbbaa02")), hci.command.call_args_list)

    def test_explicit_address_and_pta_disabled(self):
        hci = self.controller()
        bt.initialize(hci, "02:11:22:33:44:55", False)
        self.assertEqual(hci.command.call_args_list[-1], mock.call(0xfc70, bytes.fromhex("554433221102")))
        self.assertNotIn(0xfc72, [call.args[0] for call in hci.command.call_args_list])

    def test_probe_does_not_change_address_or_pta(self):
        hci = self.controller(bytes(6))
        bt.initialize(hci, probe=True)
        self.assertEqual([call.args[0] for call in hci.command.call_args_list], [0x0c03, 0x1001, 0x1009])

    def test_failed_vendor_config_prevents_success(self):
        hci = self.controller()
        original = hci.command.side_effect
        hci.command.side_effect = lambda op, payload=b"": (
            original(op, payload) if op != 0xfc72 else (_ for _ in ()).throw(OSError("vendor command failed")))
        with self.assertRaisesRegex(OSError, "vendor command failed"):
            bt.initialize(hci)

    def test_address_validation(self):
        for address in ("", "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff", "01:22:33:44:55:66", "garbage"):
            with self.assertRaises(ValueError):
                bt.parse_address(address)

    def test_pta_vendor_layout(self):
        self.assertEqual(len(bt.PTA_CONFIG), 36)
        self.assertEqual(struct.unpack_from("<HH", bt.PTA_CONFIG), (0x0b, 22))
        self.assertEqual(bt.PTA_CONFIG[26:], bytes(10))


if __name__ == "__main__":
    unittest.main()
