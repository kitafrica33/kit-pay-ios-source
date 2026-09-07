from contextlib import redirect_stdout
import io
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from ios_simulator_messaging_fixture import macho, observed_entitlements, simulator_info, write_simulator_products

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_ios_simulator_messaging as VERIFY


class SimulatorMessagingTests(unittest.TestCase):
    def test_observed_xcode_simulated_payloads_in_xml_and_binary_plists(self):
        for share in (False, True):
            for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
                with self.subTest(share=share, format=fmt):
                    expected = observed_entitlements(share=share)
                    actual = VERIFY.entitlements_from_executable(macho(plistlib.dumps(expected, fmt=fmt)))
                    self.assertEqual(actual, expected)
                    VERIFY.validate(simulator_info(share=share), actual, share=share)

    def test_device_other_architecture_and_ambiguous_platforms_are_rejected(self):
        invalid = [macho(platforms=value) for value in ((), (2,), (1,), (6,), (7, 7), (7, 2))]
        for offset, value in ((0, 0xCAFEBABE), (0, 0xCFFAEDFE), (4, 0x01000007), (8, 2), (12, 6), (28, 1)):
            data = bytearray(macho())
            struct.pack_into("<I", data, offset, value)
            invalid.append(data)
        for index, data in enumerate(invalid):
            with self.subTest(index=index), self.assertRaises(ValueError):
                VERIFY.entitlements_from_executable(data)

    def test_load_command_bounds_counts_alignment_and_legacy_platform(self):
        # Header, build-version, and segment fields in the minimal two-command fixture.
        mutations = ((16, 0), (16, 1), (16, 3), (16, 0xFFFFFFFF), (20, 0), (20, 0xFFFFFFFF),
                     (32, 0x25), (36, 0), (36, 7), (36, 16), (36, 25), (36, 0xFFFFFFF8),
                     (52, 1), (60, 72), (120, 2))
        for offset, value in mutations:
            data = bytearray(macho())
            struct.pack_into("<I", data, offset, value)
            with self.subTest(offset=offset, value=value), self.assertRaises(ValueError):
                VERIFY.entitlements_from_executable(data)
        for length in (0, 1, 31, 32, 39, 55, 127, 207, len(macho()) - 1):
            with self.subTest(length=length), self.assertRaises(ValueError):
                VERIFY.entitlements_from_executable(macho()[:length])

    def test_section_identity_type_duplicates_and_plist_shape(self):
        invalid = [macho(section_names=()), macho(section_names=(b"__text",)),
                   macho(section_names=(b"__entitlements", b"__entitlements")),
                   macho(segment=b"__DATA"), macho(flags=1), macho(flags=0xC),
                   macho(b""), macho(b"not a plist"), macho(plistlib.dumps([])),
                   macho(b"x" * (VERIFY.MAX_PLIST_BYTES + 1)),
                   macho(b'<plist version="1.0"><dict><key>a</key><string>1</string><key>a</key><string>2</string></dict></plist>')]
        for index, data in enumerate(invalid):
            with self.subTest(index=index), self.assertRaises(ValueError):
                VERIFY.entitlements_from_executable(data)

    def test_section_and_segment_offsets_and_overlaps_are_rejected(self):
        # segment at 56, section at 128. Mutate virtual/file sizes and addresses separately.
        mutations = (("Q", 80, 0x200000000), ("Q", 88, 1), ("Q", 88, 2**64 - 1), ("Q", 96, 1),
                     ("Q", 104, 0), ("Q", 104, 2**64 - 1), ("Q", 160, 0),
                     ("Q", 168, 2**64 - 1), ("I", 176, 0), ("I", 176, 2**32 - 1),
                     ("I", 180, 32), ("I", 184, 2**32 - 1), ("I", 188, 1))
        for fmt, offset, value in mutations:
            data = bytearray(macho())
            struct.pack_into("<" + fmt, data, offset, value)
            with self.subTest(offset=offset, value=value), self.assertRaises(ValueError):
                VERIFY.entitlements_from_executable(data)
        data = bytearray(macho(section_names=(b"__entitlements", b"__other")))
        struct.pack_into("<I", data, 256, struct.unpack_from("<I", data, 176)[0])
        with self.assertRaisesRegex(ValueError, "Overlapping"):
            VERIFY.entitlements_from_executable(data)
        data = bytearray(macho())
        data[128 + 16:128 + 32] = b"__DATA".ljust(16, b"\0")
        with self.assertRaises(ValueError):
            VERIFY.entitlements_from_executable(data)

    def test_empty_codesign_dictionary_cannot_replace_embedded_policy(self):
        for share in (False, True):
            with self.subTest(share=share), self.assertRaises(ValueError):
                VERIFY.validate(simulator_info(share=share), {}, share=share)

    def test_bundle_platform_executable_and_prefix_are_bound(self):
        for share in (False, True):
            for key, value in (("CFBundleIdentifier", "another.app"), ("CFBundleExecutable", "../KitPay"),
                               ("CFBundlePackageType", "BNDL"), ("DTPlatformName", "iphoneos"),
                               ("CFBundleSupportedPlatforms", ["iPhoneSimulator", "iPhoneOS"]),
                               ("KitMessagingKeychainGroup", "KITSIM0001.africa.kit.pay.ios.messaging"),
                               ("KitMessagingKeychainGroup", "$(AppIdentifierPrefix)africa.kit.pay.ios.messaging")):
                info = simulator_info(share=share)
                info[key] = value
                with self.subTest(share=share, key=key), self.assertRaises(ValueError):
                    VERIFY.validate(info, observed_entitlements(share=share), share=share)
            entitlements = observed_entitlements(share=share)
            entitlements["application-identifier"] = "FAKETEAMID.another.app"
            with self.assertRaises(ValueError):
                VERIFY.validate(simulator_info(share=share), entitlements, share=share)

    def test_exact_keychain_isolation_includes_order_and_no_wildcards(self):
        private = "FAKETEAMID.africa.kit.pay.ios"
        shared = private + ".messaging"
        for share, groups in ((False, [shared, private]), (False, [shared]), (True, [private, shared]),
                              (True, [shared, shared]), (True, ["FAKETEAMID.*"]), (True, []),
                              (True, shared), (False, [private, shared, "other.group"])):
            entitlements = observed_entitlements(share=share)
            entitlements["keychain-access-groups"] = groups
            with self.subTest(share=share, groups=groups), self.assertRaises(ValueError):
                VERIFY.validate(simulator_info(share=share), entitlements, share=share)

    def test_products_are_read_only_and_signature_failure_is_fatal(self):
        with tempfile.TemporaryDirectory() as raw:
            app = Path(raw) / "KitPay.app"
            write_simulator_products(app)
            before = {str(path.relative_to(app)): (path.read_bytes(), path.stat().st_mtime_ns)
                      for path in app.rglob("*") if path.is_file()}
            output = io.StringIO()
            with patch.object(VERIFY.subprocess, "run") as run, redirect_stdout(output):
                VERIFY.verify_products(app)
                run.assert_called_once_with(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
            self.assertIn('"simulatorMessagingVerified": true', output.getvalue())
            self.assertIn('"keychainGroups": ["FAKETEAMID.africa.kit.pay.ios.messaging"]', output.getvalue())
            with patch.object(VERIFY.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "codesign")), redirect_stdout(io.StringIO()):
                with self.assertRaises(subprocess.CalledProcessError):
                    VERIFY.verify_products(app)
            after = {str(path.relative_to(app)): (path.read_bytes(), path.stat().st_mtime_ns)
                     for path in app.rglob("*") if path.is_file()}
            self.assertEqual(before, after)

    def test_missing_or_redirected_products_are_not_accepted(self):
        for relative in ("Info.plist", "KitPay", "PlugIns/KitPayShare.appex/Info.plist",
                         "PlugIns/KitPayShare.appex/KitPayShare"):
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as raw:
                app = Path(raw) / "KitPay.app"
                write_simulator_products(app)
                selected = app / relative
                target = Path(raw) / "external"
                selected.rename(target)
                selected.symlink_to(target)
                with redirect_stdout(io.StringIO()), patch.object(VERIFY.subprocess, "run") as run:
                    with self.assertRaises(ValueError):
                        VERIFY.verify_products(app)
                    run.assert_not_called()

    def test_relative_bundle_name_cannot_become_a_codesign_option(self):
        with tempfile.TemporaryDirectory() as raw:
            app = Path(raw) / "--help"
            write_simulator_products(app)
            with patch("os.getcwd", return_value=raw), patch.object(VERIFY.subprocess, "run") as run, redirect_stdout(io.StringIO()):
                VERIFY.verify_products(Path("--help"))
                self.assertEqual(run.call_args.args[0][-1], str(app))

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO creation is unavailable")
    def test_info_plist_fifo_is_rejected_without_reading_it(self):
        with tempfile.TemporaryDirectory() as raw:
            app = Path(raw) / "KitPay.app"
            write_simulator_products(app)
            info = app / "Info.plist"
            info.unlink()
            os.mkfifo(info)
            with self.assertRaisesRegex(ValueError, "non-file"), patch.object(VERIFY.subprocess, "run") as run:
                VERIFY.verify_products(app)
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
