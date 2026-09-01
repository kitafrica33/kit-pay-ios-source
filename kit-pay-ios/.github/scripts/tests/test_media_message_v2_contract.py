"""Structural guards for the KITMEDIA2 media-message-v2 source (contract v0.4, 449925d9…).

Behaviour is pinned by `KitPayTests/MediaMessageV2ContractTests.swift` (which also runs on Linux
via `.github/scripts/tests/run_media_v2_linux_gate.sh`). This suite pins what a Swift test cannot:
that the deliberately duplicated pieces of `MediaMessageV2Models.swift` never drift from their
v1 originals in `MessagingAPIModels.swift`, that the v2 path stays off platform trims, that the
file stays Foundation-only (Linux-compilable), and that both new files remain registered in the
Xcode project.
"""

from __future__ import annotations

import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
V2_MODELS = ROOT / "KitPay/Core/MediaMessageV2Models.swift"
V1_MODELS = ROOT / "KitPay/Core/MessagingAPIModels.swift"
MODELS = ROOT / "KitPay/Core/Models.swift"
BACKGROUND_UPLOAD = ROOT / "KitPay/Core/MessagingBackgroundUpload.swift"
API_CLIENT = ROOT / "KitPay/Core/APIClient.swift"
MESSAGING_API = ROOT / "KitPay/Core/APIClient+Messaging.swift"
COORDINATOR = ROOT / "KitPay/Core/SecureMessagingCoordinator.swift"
APP_DELEGATE = ROOT / "KitPay/App/NotificationCoordinator.swift"
V2_TESTS = ROOT / "KitPayTests/MediaMessageV2ContractTests.swift"
WIRE_GLUE_TESTS = ROOT / "KitPayTests/MediaMessageV2WireGlueTests.swift"
PBXPROJ = ROOT / "KitPay.xcodeproj/project.pbxproj"
LINUX_GATE = ROOT / ".github/scripts/tests/run_media_v2_linux_gate.sh"
LINUX_MAIN = ROOT / ".github/scripts/tests/media_v2_linux_gate/main.swift"


def function_body(source: str, signature_marker: str) -> list[str]:
    """Lines between a function's opening line and its matching close, indentation-stripped."""
    lines = source.splitlines()
    for index, line in enumerate(lines):
        if signature_marker in line:
            indent = len(line) - len(line.lstrip())
            closing = " " * indent + "}"
            for end in range(index + 1, len(lines)):
                if lines[end] == closing:
                    return [body.strip() for body in lines[index + 1 : end]]
            raise AssertionError(f"unterminated function for {signature_marker!r}")
    raise AssertionError(f"{signature_marker!r} not found")


def set_literal(source: str, declaration_marker: str) -> set[str]:
    """String elements of a `Set<String> = [ ... ]` literal starting at the marker line."""
    lines = source.splitlines()
    for index, line in enumerate(lines):
        if declaration_marker in line:
            elements: set[str] = set()
            for element_line in lines[index + 1 :]:
                stripped = element_line.strip()
                if stripped.startswith("]"):
                    return elements
                match = re.fullmatch(r'"([^"]+)",?', stripped)
                if match:
                    elements.add(match.group(1))
            raise AssertionError(f"unterminated set literal for {declaration_marker!r}")
    raise AssertionError(f"{declaration_marker!r} not found")


class MediaMessageV2SourceContract(unittest.TestCase):
    def setUp(self) -> None:
        self.v2 = V2_MODELS.read_text(encoding="utf-8")
        self.v1 = V1_MODELS.read_text(encoding="utf-8")
        self.models = MODELS.read_text(encoding="utf-8")

    def test_media_loader_delegates_downloads_to_verified_file_hydration(self) -> None:
        """The identity-addressed loader must route remote media through the streaming,
        authenticated file hydrator. It must not reintroduce the old whole-Data cache-write path
        (which could both block rendering and clobber another loader's local representation)."""
        app_model = (ROOT / "KitPay/App/AppModel.swift").read_text(encoding="utf-8")
        start = app_model.index("func loadSecureMediaItem(")
        end = app_model.index("func queueDirectMessage(", start)
        loader = app_model[start:end]
        self.assertEqual(loader.count("loadProtectedLocalMediaFile("), 2)
        self.assertNotIn("insertIfAbsent(", loader)
        self.assertNotIn("SecureMediaFileCache.shared.store(", loader)

    def test_percent_encode_bodies_are_identical(self) -> None:
        """§4: v2 percent-encoding MUST byte-match v1's percentEncode; the body is duplicated
        so the v2 core stays Foundation-only, so drift here silently forks the wire format."""
        v2_body = function_body(self.v2, "func percentEncode(_ value: String) -> String {")
        v1_body = function_body(self.v1, "func percentEncode(_ value: String) -> String {")
        self.assertEqual(v2_body, v1_body)

    def test_allowed_media_types_match_wire_list(self) -> None:
        v2_types = set_literal(self.v2, "allowedAttachmentMediaTypes: Set<String> = [")
        v1_types = set_literal(self.v1, "allowedAttachmentMediaTypes: Set<String> = [")
        self.assertEqual(v2_types, v1_types)
        self.assertEqual(len(v2_types), 22)

    def test_v2_core_never_uses_platform_trim(self) -> None:
        """§4 cap rule: only the explicit six-codepoint helpers may trim on the v2 path.
        (Comments may — and do — mention the forbidden APIs to warn against them.)"""
        code_lines = [
            line for line in self.v2.splitlines() if not line.lstrip().startswith("//")
        ]
        for line in code_lines:
            self.assertNotIn("whitespacesAndNewlines", line, f"platform trim in code: {line!r}")
            self.assertNotIn(".trimmingCharacters", line, f"platform trim in code: {line!r}")
        for escape in ("0009", "000A", "000B", "000C", "000D", "0020"):
            self.assertIn(f'"\\u{{{escape}}}"', self.v2,
                          f"six-codepoint set must spell U+{escape} explicitly")

    def test_v2_core_is_foundation_only(self) -> None:
        """The Linux contract gate compiles this file with a stock toolchain; any UIKit/Crypto
        import would break it (and would be a sign policy code is growing UI tendrils)."""
        imports = re.findall(r"^import\s+(\S+)", self.v2, flags=re.MULTILINE)
        self.assertEqual(imports, ["Foundation"])

    def test_descriptor_confinement_constants_present(self) -> None:
        for constant in (
            'prefix = "KITMEDIA2:"',
            "maximumDescriptorUTF8Bytes = 7_680",
            "maximumCaptionUTF8Bytes = 2_048",
            "minimumAttachmentCount = 2",
            "maximumAttachmentCount = 8",
            "keyMaterialBytes = 64",
            'featureKey = "messaging_media_message_v2"',
            'profile = "kit-media-v2"',
        ) :
            self.assertIn(constant, self.v2)

    def test_project_registration(self) -> None:
        text = PBXPROJ.read_text(encoding="utf-8")
        self.assertIn("path = KitPay/Core/MediaMessageV2Models.swift", text)
        self.assertIn("path = KitPayTests/MediaMessageV2ContractTests.swift", text)
        self.assertIn("path = KitPayTests/MediaMessageV2WireGlueTests.swift", text)
        self.assertTrue(WIRE_GLUE_TESTS.is_file())
        # One PBXBuildFile + one Sources-phase mention; one PBXFileReference + one group child
        # + the PBXBuildFile back-reference.
        self.assertEqual(text.count("A41000000000000000000001"), 2)
        self.assertEqual(text.count("B41000000000000000000001"), 3)
        self.assertEqual(text.count("A42000000000000000000001"), 2)
        self.assertEqual(text.count("B42000000000000000000001"), 3)
        self.assertEqual(text.count("A42000000000000000000002"), 2)
        self.assertEqual(text.count("B42000000000000000000002"), 3)

    def test_resumable_chunks_use_a_relaunchable_file_backed_background_session(self) -> None:
        """A durable spool/offset alone cannot keep an in-flight request alive after process
        termination. Production PATCHes must use the dedicated background session, while the
        coordinator keeps the protocol's authoritative-offset validation and checkpointing."""
        background = BACKGROUND_UPLOAD.read_text(encoding="utf-8")
        api = API_CLIENT.read_text(encoding="utf-8")
        messaging_api = MESSAGING_API.read_text(encoding="utf-8")
        coordinator = COORDINATOR.read_text(encoding="utf-8")
        app_delegate = APP_DELEGATE.read_text(encoding="utf-8")
        project = PBXPROJ.read_text(encoding="utf-8")

        self.assertIn("URLSessionConfiguration.background(", background)
        self.assertIn("sessionSendsLaunchEvents = true", background)
        self.assertIn("uploadTask(with: request, fromFile: chunkURL)", background)
        self.assertIn("task.taskDescription = description", background)
        self.assertIn("accountFingerprint", background)
        self.assertIn("sessionFingerprint", background)
        self.assertIn("accessTokenFingerprint", background)
        self.assertIn("persistDurableResult(result)", background)
        self.assertIn("sendBackgroundAttachmentChunk", api)
        self.assertIn("uploadMessagingAttachmentChunkInBackground", messaging_api)
        self.assertIn(".uploadMessagingAttachmentChunkInBackground(", coordinator)
        self.assertIn("handleEventsForBackgroundURLSession", app_delegate)
        self.assertEqual(project.count("A43000000000000000000001"), 2)
        self.assertEqual(project.count("B43000000000000000000001"), 3)

    def test_shared_inbox_and_voice_adoption_do_not_scale_with_file_bytes(self) -> None:
        """Shared files are already local and protected, so the containing app may do metadata
        work but must not synchronously duplicate every byte before the composer appears. Voice
        segments are app-owned scratch files and must use same-volume moves before queueing."""
        cache = (ROOT / "KitPay/Core/SecureMediaFileCache.swift").read_text(encoding="utf-8")
        messages = (ROOT / "KitPay/Features/Messages/MessagesView.swift").read_text(
            encoding="utf-8"
        )
        shared_start = messages.index("private func stageSharedInbox(")
        shared_end = messages.index("private func preparedSharedItem(", shared_start)
        shared = messages[shared_start:shared_end]
        voice_start = messages.index("private func sendVoiceNote()")
        voice_end = messages.index("private func recoverUnqueuedVoiceNote(", voice_start)
        voice = messages[voice_start:voice_end]

        self.assertIn("clonefile(sourcePath, destinationPath, 0)", cache)
        self.assertIn("requiresConstantTimeClone: true", shared)
        self.assertNotIn("Data(contentsOf:", shared)
        self.assertIn("moveSource: true", voice)
        self.assertLess(voice.index("persistStagedMediaOriginal("), voice.index("queueMediaMessage("))

    def test_video_original_is_published_before_optional_trim(self) -> None:
        """Camera/library video must become an app-owned playable draft before the editor runs.
        Reopening trim over a staged file must read the permanent source directly rather than
        making another whole-file copy on the capture-to-visible path."""
        messages = (ROOT / "KitPay/Features/Messages/MessagesView.swift").read_text(
            encoding="utf-8"
        )
        camera_stage = "\n".join(function_body(messages, "private func stageCapturedVideo("))
        library_stage = "\n".join(
            function_body(messages, "private func openLibraryVideoInEditor(")
        )
        trim = "\n".join(
            function_body(messages, "private func beginTrimmingStagedVideo(")
        )

        for staging_path in (camera_stage, library_stage):
            self.assertLess(
                staging_path.index("persistStagedMediaOriginal("),
                staging_path.index("stageAttachment("),
            )
            self.assertLess(
                staging_path.index("stageAttachment("),
                staging_path.index("beginTrimmingStagedVideo("),
            )
        self.assertIn("url = sourceURL", trim)
        self.assertIn("ownsInputFile = false", trim)
        self.assertNotIn("copyItem(", trim)

    def test_passive_media_rendering_uses_bounded_decoding(self) -> None:
        """Conversation bubbles and the gallery page must not inflate arbitrary source pixels.
        Explicit share/save actions may still request a full representation after a user tap."""
        views = (ROOT / "KitPay/Features/Messages/ChatMediaViews.swift").read_text(
            encoding="utf-8"
        )
        gallery = (ROOT / "KitPay/Features/Messages/KitMediaGalleryView.swift").read_text(
            encoding="utf-8"
        )
        thumbnails = (ROOT / "KitPay/Features/Messages/ChatMediaThumbnails.swift").read_text(
            encoding="utf-8"
        )
        page_start = gallery.index("private struct GalleryImagePage")
        page = gallery[page_start:]
        view_code = "\n".join(
            line for line in views.splitlines() if not line.lstrip().startswith("//")
        )
        page_code = "\n".join(
            line for line in page.splitlines() if not line.lstrip().startswith("//")
        )

        self.assertNotIn("UIImage(data:", view_code)
        self.assertNotIn("UIImage.init(data:", view_code)
        self.assertIn("downsampledImage(", view_code)
        self.assertIn("CGImageSourceCreateWithURL", thumbnails)
        self.assertIn("maximumPixelSize: 4_096", page_code)
        self.assertNotIn("UIImage(data:", page_code)

    def test_explicit_gallery_dismissal_does_not_start_picture_in_picture(self) -> None:
        """Closing, dragging away, and Show in chat share dismissGallery. Those explicit user
        exits must stop playback; only an app background transition may retain it in PiP."""
        gallery = (ROOT / "KitPay/Features/Messages/KitMediaGalleryView.swift").read_text(
            encoding="utf-8"
        )
        picture_in_picture = (
            ROOT / "KitPay/Features/Messages/ChatVideoPictureInPicture.swift"
        ).read_text(encoding="utf-8")
        dismiss = "\n".join(function_body(gallery, "private func dismissGallery()"))
        self.assertIn("stopForExplicitViewerDismissal()", dismiss)
        self.assertNotIn("startIfPlaying()", dismiss)
        self.assertIn("func stopForExplicitViewerDismissal()", picture_in_picture)

    def test_ready_leases_are_replayed_at_the_sealing_boundary(self) -> None:
        """Resumable ciphertext must stay retained until an exact READY replay immediately
        before sealing; a swept batch item reopens without changing local identity/key material."""
        coordinator = COORDINATOR.read_text(encoding="utf-8")
        batch_start = coordinator.index("batchUploadAndRenewal: while true")
        batch_end = coordinator.index("mediaMessageV2Items = draftItems", batch_start)
        batch = coordinator[batch_start:batch_end]
        upload_start = coordinator.index("private func uploadDeferredMediaDescriptor(")
        upload_end = coordinator.index("static func validatedResumableCheckpoint(", upload_start)
        single = coordinator[upload_start:upload_end]

        for path in (batch, single):
            self.assertIn("beginMessagingAttachmentUpload(", path)
            self.assertIn("validatedResumableLeasePreflight(", path)
        self.assertIn("reopeningUpload()", batch)
        self.assertLess(
            batch.index("validatedResumableLeasePreflight("),
            batch.index("removeCiphertextSpool"),
        )

    def test_fanout_promotion_retains_sender_local_media_records(self) -> None:
        """Replacing a sealed pending row with its Signal fanout must retain the sender's
        permanent local-media references; the remote descriptor can never become its sole key."""
        coordinator = COORDINATOR.read_text(encoding="utf-8")
        queue_text = "\n".join(function_body(coordinator, "private func queueText("))
        self.assertIn(
            "localMediaRecords: existingMessage?.localMediaRecords",
            queue_text,
        )

    def test_content_binding_intercepts_the_v2_prefix(self) -> None:
        """The kind() dispatcher must strict-parse v2-prefixed bodies BEFORE the plain-text
        fallthrough, or `encrypted` smuggles a raw descriptor — every attachment key — into a
        rendered text bubble. Behaviour is pinned by MediaMessageV2WireGlueTests; this pins
        that the branch physically stays inside the shared dispatcher."""
        body = function_body(
            self.v1,
            "static func kind(",
        )
        joined = "\n".join(body)
        self.assertIn("KitMediaMessageV2Descriptor.prefix", joined)
        self.assertIn("KitMediaMessageV2Descriptor.parse(plaintext)", joined)
        # The v2 interception must come before the v1/plain-text tail.
        self.assertLess(
            joined.index("KitMediaMessageV2Descriptor.prefix"),
            joined.index("KitMediaMessageDescriptor.attachments(for: plaintext)"),
        )

    def test_send_request_enforces_canonical_multi_row_order(self) -> None:
        """§5: multi-row sends must hit the wire in ascending-id order with lowercase digests
        and at most 8 rows; the guard lives in SendEncryptedMessageRequest so no future call
        site can skip it."""
        body = "\n".join(function_body(self.v1, "struct SendEncryptedMessageRequest"))
        self.assertIn("KitMediaMessageV2Descriptor.isCanonicalOuterOrder(", body)
        self.assertIn("KitMediaMessageV2Descriptor.maximumAttachmentCount", body)
        self.assertIn("SecureMessagingWirePolicy.isLowercaseSHA256($0.ciphertextSha256)", body)

    def test_user_authored_text_guard_does_not_block_the_media_family(self) -> None:
        """Contract §4 rule 6 / starter milestone: a VALIDATED media message is first-class for
        downstream product logic, and the starter milestone gates on allowsUserAuthoredText —
        so that policy must never learn a KITMEDIA prefix. Family blocking of typed/pasted/
        edited input belongs at the composer call sites via KitMediaMessageFamilyPolicy."""
        body = "\n".join(function_body(self.v1, "static func allowsUserAuthoredText("))
        self.assertNotIn("KITMEDIA", body)
        self.assertIn(
            "static func blocksUserAuthoredText(_ text: String) -> Bool",
            self.v2,
        )

    def test_capabilities_decode_isolates_the_media_message_block(self) -> None:
        """§6: `protocols.messaging.media_message` must decode tolerantly (the `try?` realtime
        precedent) so a malformed advertisement disables only the multi-attachment path, while
        the legacy `rich_media` field keeps its strict decode; and the enablement accessor must
        AND the features key with the coherent block, so either leg failing keeps it off."""
        dto = "\n".join(function_body(self.models, "struct MessagingProtocolCapabilityDTO"))
        self.assertIn('case mediaMessage = "media_message"', dto)
        self.assertIn("mediaMessage = try? values.decodeIfPresent(", dto)
        self.assertIn("richMedia = try values.decodeIfPresent(", dto)
        accessor = "\n".join(
            function_body(self.models, "var enablesMessagingMediaMessageV2: Bool {")
        )
        self.assertIn(
            "supportsFeature(MessagingMediaMessageV2CapabilityPolicy.featureKey)", accessor
        )
        self.assertIn("supportsIOSV2 == true", accessor)

    def test_sender_admission_gate_is_atomic(self) -> None:
        """§6: sender admission is one question — server feature+profile, unanimous roster
        attestation, at least one recipient peer (never a vacuous allSatisfy), per-item §4
        envelope plus the per-item v1 rich-media/extended-size keys, and the aggregate ceiling —
        so no call site can pair a fresh answer for one leg with a stale answer for another."""
        body = "\n".join(function_body(self.v1, "static func admitsComposition("))
        self.assertIn("enablesMessagingMediaMessageV2 == true", body)
        self.assertIn("!recipientUserIDs.isEmpty", body)
        self.assertIn("MessagingRosterCapabilityPolicy.supports(", body)
        self.assertIn("MessagingRichMediaCapabilityPolicy.supportsAcrossRoster(", body)
        self.assertIn(
            "MessagingRichMediaCapabilityPolicy.supportsPlaintextByteSizeAcrossRoster(", body
        )
        self.assertIn("maximumAggregateCiphertextBytes", body)

    def test_recipient_hydration_republishes_final_child_states_before_retry(self) -> None:
        """Concurrent children can finish out of order. The retry decision must follow a fresh
        protected-store projection so a late failure cannot remain published as downloading."""
        app_model = (ROOT / "KitPay/App/AppModel.swift").read_text(encoding="utf-8")
        start = app_model.index("private func schedulePendingMediaHydration()")
        end = app_model.index("private var hasPendingReceivedMediaHydration", start)
        body = app_model[start:end]
        run = body.index("await self.runPendingMediaHydration")
        publish = body.index("await self.publishLatestState()", run)
        pending_after = body.index("let pendingAfter", publish)
        self.assertLess(run, publish)
        self.assertLess(publish, pending_after)

    def test_direct_recipient_hydration_failure_is_republished_for_retry(self) -> None:
        """A visible bubble can invoke hydration without the background pass. Its failure must
        leave the published row in `failed`, not stranded in the intermediate downloading state."""
        app_model = (ROOT / "KitPay/App/AppModel.swift").read_text(encoding="utf-8")
        start = app_model.index("func loadProtectedLocalMediaFile(")
        end = app_model.index("private func schedulePendingMediaHydration()", start)
        body = app_model[start:end]
        failure = body.index("LocalMediaRecordPolicy.markDownloadFailed(")
        publish = body.index("await publishLatestState()", failure)
        self.assertLess(failure, publish)

    def test_composer_media_has_an_encrypted_restart_manifest(self) -> None:
        models = (ROOT / "KitPay/Core/Models.swift").read_text(encoding="utf-8")
        messages = (ROOT / "KitPay/Features/Messages/MessagesView.swift").read_text(
            encoding="utf-8"
        )
        coordinator = COORDINATOR.read_text(encoding="utf-8")
        self.assertIn("struct ConversationDraftMediaAttachment", models)
        self.assertIn(
            "let mediaAttachments: [ConversationDraftMediaAttachment]?",
            models,
        )
        self.assertIn("restoredConversationDraftMedia(", messages)
        self.assertIn("mediaAttachments: submittedDraftMediaAttachments", messages)
        self.assertIn(
            "submittedMediaAttachments: submittedDraftMediaAttachments",
            coordinator,
        )

    def test_send_waits_for_async_media_draft_restoration(self) -> None:
        """A fast tap during relaunch must not clear an attachment manifest that the async
        protected-file restoration has not projected into the composer yet."""
        messages = (ROOT / "KitPay/Features/Messages/MessagesView.swift").read_text(
            encoding="utf-8"
        )
        send = "\n".join(function_body(messages, "private func sendDraft("))
        voice = "\n".join(function_body(messages, "private func sendVoiceNote()"))
        self.assertIn("guard didRestoreDraft", send)
        self.assertIn("guard didRestoreDraft", voice)
        can_send_start = messages.index("private var canSendMessage: Bool")
        can_send_end = messages.index("private var cameraPullIsEligible", can_send_start)
        self.assertIn("&& didRestoreDraft", messages[can_send_start:can_send_end])
        restore_start = messages.index("let restored = await model.restoredConversationDraftMedia(")
        restore_end = messages.index(
            "stagedAttachments.insert(contentsOf: newAttachments", restore_start
        )
        self.assertNotIn(
            "LocalMediaPerformanceMonitor.shared.begin",
            messages[restore_start:restore_end],
        )

    def test_camera_preserves_avcapturephoto_bytes_before_background_processing(self) -> None:
        camera = (ROOT / "KitPay/Features/Messages/KitCameraController.swift").read_text(
            encoding="utf-8"
        )
        messages = (ROOT / "KitPay/Features/Messages/MessagesView.swift").read_text(
            encoding="utf-8"
        )
        capture = "\n".join(function_body(camera, "func photoOutput("))
        stage = "\n".join(function_body(messages, "private func stageCapturedPhoto("))
        self.assertIn("photo.fileDataRepresentation()", capture)
        self.assertIn("KitCaptureTemporaryFileStore.makeFileURL(", capture)
        self.assertIn("case photo(fileURL: URL", camera)
        self.assertLess(stage.index("stageAttachment("), stage.index("persistStagedMediaOriginal("))
        self.assertIn("originalMediaType: mediaType", stage)

    def test_concurrent_hydration_reserves_aggregate_disk_and_rotates_failures(self) -> None:
        app_model = (ROOT / "KitPay/App/AppModel.swift").read_text(encoding="utf-8")
        load = "\n".join(function_body(app_model, "func loadProtectedLocalMediaFile("))
        run = "\n".join(function_body(app_model, "private func runPendingMediaHydration("))
        self.assertIn("reserveReceivedMediaHydrationCapacity(", load)
        self.assertIn("defer { receivedMediaHydrationReservations", load)
        self.assertIn("lastAttemptAt", run)
        self.assertIn("targets.sorted", run)

    def test_preprocessing_overlaps_only_independent_outbox_commands(self) -> None:
        app_model = (ROOT / "KitPay/App/AppModel.swift").read_text(encoding="utf-8")
        run = "\n".join(function_body(app_model, "private func runPendingMediaPreprocessing("))
        self.assertIn("targetsByCommand", run)
        self.assertIn("MediaPreprocessingPolicy.maximumConcurrentJobs", run)
        self.assertIn("withTaskGroup", run)
        self.assertIn("processPendingMediaPreprocessingTargets(", run)
        self.assertIn("lastAttemptAt", run)
        self.assertIn("targets.sorted", run)

    def test_preprocessing_validates_crash_output_and_rekeys_without_inline_removal(self) -> None:
        app_model = (ROOT / "KitPay/App/AppModel.swift").read_text(encoding="utf-8")
        policy = "\n".join(function_body(app_model, "static func canReplaceOutput("))
        validator = "\n".join(function_body(app_model, "static func isValidPublishedOutput("))
        rekey = "\n".join(function_body(app_model, "private func rekeyInvalidPreprocessingOutput("))
        preprocess = "\n".join(function_body(app_model, "private func preprocessLocalMedia("))
        self.assertIn("localMediaStorageKeysOwnedByDrafts", policy)
        self.assertIn("recordOwners.count == 1", policy)
        self.assertIn("owner.record.preprocessingJob == expectedJob", policy)
        self.assertIn("MediaPreprocessingPolicy.canReplaceOutput(", preprocess)
        self.assertNotIn("SecureMediaFileCache.shared.remove(", preprocess)
        self.assertIn("CGImageSourceCreateThumbnailAtIndex", validator)
        self.assertIn("asset.loadTracks(withMediaType: .audio)", validator)
        self.assertIn("probeProtectedOriginal(", preprocess)
        self.assertNotIn("SecureMediaFileCache.shared.byteCount(", preprocess)
        self.assertIn("MediaPreprocessingPolicy.isValidPublishedOutput(", preprocess)
        self.assertIn("rekeyInvalidPreprocessingOutput(", preprocess)
        self.assertIn("MediaPreprocessingPolicy.canReplaceOutput(", rekey)
        self.assertIn("MediaPreprocessingPolicy.isOutputStorageKeyUnowned(", rekey)
        self.assertIn("LocalMediaRecordPolicy.rekeyPreprocessingOutput(", rekey)
        self.assertNotIn("SecureMediaFileCache.shared.remove(", rekey)
        self.assertLess(
            preprocess.rindex("MediaPreprocessingPolicy.canReplaceOutput("),
            preprocess.index("SecureMediaFileCache.shared.importProtectedOriginal("),
        )

    def test_queue_collision_namespace_includes_record_ids_and_storage_keys(self) -> None:
        models = (ROOT / "KitPay/Core/Models.swift").read_text(encoding="utf-8")
        coordinator = (ROOT / "KitPay/Core/SecureMessagingCoordinator.swift").read_text(
            encoding="utf-8"
        )
        ownership = "\n".join(function_body(models, "var localMediaOwnershipClaims:"))
        storage_admission = "\n".join(
            function_body(models, "static func permitsTransition(")
        )
        replacement = "\n".join(
            function_body(coordinator, "private func replaceDeferredMessageProjection(")
        )
        single = "\n".join(function_body(coordinator, "func queueDeferredImage("))
        batch = "\n".join(function_body(coordinator, "func queueDeferredMediaBatch("))
        draft_store = "\n".join(function_body(models, "static func store("))
        self.assertIn("record.id", ownership)
        self.assertIn("record.preprocessingJob?.outputStorageKey", ownership)
        self.assertIn("localMediaStorageKeysOwnedByDrafts", storage_admission)
        self.assertIn("proposedClaimsOnlyTargetServerRoles", storage_admission)
        self.assertIn("LocalMediaStorageOwnershipPolicy.permitsTransition", replacement)
        self.assertIn("proposedOwnershipKeys", single)
        self.assertIn("localMediaOwnershipKeys", single)
        self.assertIn("offeredOwnershipKeys", batch)
        self.assertIn("localMediaOwnershipKeys", batch)
        self.assertIn("localMediaOwnershipKeys", draft_store)

    def test_server_storage_keys_are_target_bound_inside_the_projection_cas(self) -> None:
        models = (ROOT / "KitPay/Core/Models.swift").read_text(encoding="utf-8")
        coordinator = (ROOT / "KitPay/Core/SecureMessagingCoordinator.swift").read_text(
            encoding="utf-8"
        )
        admission = "\n".join(function_body(models, "static func permitsTransition("))
        binding_derivation = "\n".join(function_body(models, "static func bindings("))
        replacement = "\n".join(
            function_body(coordinator, "private func replaceDeferredMessageProjection(")
        )
        preparation = "\n".join(function_body(coordinator, "func prepareDeferredMessage("))
        self.assertIn("localMediaStorageKeysOwnedByDrafts", admission)
        self.assertIn("current.localMediaOwnershipClaims", admission)
        self.assertIn("proposedClaimsOnlyTargetServerRoles", admission)
        self.assertIn("record.resumableUpload?.storageKey", binding_derivation)
        self.assertIn("record.remoteEncryptedObjectID", binding_derivation)
        self.assertIn("LocalMediaStorageOwnershipPolicy.permitsTransition", replacement)
        self.assertEqual(coordinator.count("LocalMediaRecordPolicy.setResumableUpload("), 4)
        self.assertEqual(
            coordinator.count("LocalMediaRecordPolicy.replaceCompletedResumableUpload("),
            1,
        )
        self.assertNotIn("removeDuplicate(", preparation)

    def test_single_media_queue_never_deletes_scratch_after_an_await(self) -> None:
        app_model = (ROOT / "KitPay/App/AppModel.swift").read_text(encoding="utf-8")
        queue = "\n".join(function_body(app_model, "func queueMediaMessage("))
        self.assertIn("insertIfAbsent(", queue)
        self.assertNotIn("SecureMediaFileCache.shared.remove(", queue)
        self.assertIn("age-gated orphan sweep", queue)

    def test_local_media_admission_never_waits_for_network_capabilities(self) -> None:
        """A selected original and its pending bubble must commit without a capability request.
        Service and device compatibility remain mandatory at the background upload boundary."""
        app_model = (ROOT / "KitPay/App/AppModel.swift").read_text(encoding="utf-8")
        coordinator = COORDINATOR.read_text(encoding="utf-8")
        single = "\n".join(function_body(app_model, "func queueMediaMessage("))
        batch = "\n".join(function_body(app_model, "func queueMediaMessageBatch("))
        upload = "\n".join(
            function_body(coordinator, "private func uploadDeferredMediaDescriptor(")
        )

        for queue in (single, batch):
            self.assertNotIn("reloadCapabilities()", queue)
        self.assertNotIn("enablesMessagingRichMedia", single)
        self.assertNotIn("enablesMessagingMediaMessageV2", batch)
        self.assertIn("queueDeferredImage(", single)
        self.assertIn("queueDeferredMediaBatch(", batch)
        self.assertIn("requiresAdvertisedRichMediaCapability", upload)
        self.assertEqual(upload.count("capabilities.enablesMessagingRichMedia"), 2)
        self.assertLess(
            upload.index("prepareCiphertextSpool"),
            upload.index("capabilities.enablesMessagingRichMedia"),
        )
        self.assertLess(
            upload.index("capabilities.enablesMessagingRichMedia"),
            upload.index("uploadMessagingAttachment("),
        )

    def test_linux_gate_compiles_production_sources(self) -> None:
        gate = LINUX_GATE.read_text(encoding="utf-8")
        for path in (
            "KitPay/Core/MediaMessageV2Models.swift",
            "KitPayTests/MediaMessageV2ContractTests.swift",
            ".github/scripts/tests/media_v2_linux_gate/main.swift",
        ):
            self.assertIn(path, gate)
        self.assertIn("MediaMessageV2ContractTests.allTests", LINUX_MAIN.read_text(encoding="utf-8"))
        self.assertIn("static var allTests", V2_TESTS.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
