# Local Voice 3.2.0 (321) — App Review response

## Resolution Center reply

Hello App Review Team,

Thank you for the detailed review. We addressed the actionable issues in the new build:

1. **Guideline 5.2.5 — Apple trademarks**
   We removed “Mac” from the App Store subtitle. The subtitle is now **“Private AI Voice Typing.”**

2. **Guideline 5.1.1(iv) — microphone pre-permission screen**
   The button shown before the macOS microphone permission dialog now says **“Continue,”** not “Allow.” The operating system remains the only place where the user grants or denies microphone access.

3. **Guideline 4 — reopening the main window**
   We added **Window → Open Local Voice** with the keyboard shortcut **Command-0**. It opens the main window again after the user closes it. The existing Dock and menu-bar reopening flows remain available as well.

4. **Guideline 2.4.5 — Accessibility permission**
   We respectfully request reconsideration because Accessibility permission is used only for the app’s primary, user-initiated voice-typing operation.

   The user explicitly starts dictation with a configured shortcut, speaks, and stops dictation. Local Voice transcribes that speech locally and uses Accessibility only to insert the resulting text into the text field that the user is actively editing. This preserves the core voice-typing workflow across third-party applications that do not provide a shared public text-insertion API.

   Local Voice does not use Accessibility to read passwords, monitor applications in the background, inspect unrelated interface content, control application workflows, or collect or transmit UI data. Text insertion occurs only immediately after the user invokes dictation. The permission is disclosed during onboarding, granted through macOS System Settings, and can be revoked at any time.

   Replacing this operation with clipboard-only output would remove the app’s principal feature: direct, user-requested voice typing into the current editor. If there is a public macOS API suitable for inserting user-generated text into the currently focused text field across arbitrary applications without Accessibility permission, please let us know and we will adopt it. Otherwise, we ask that this narrow, transparent, and user-initiated use be considered acceptable.

The Lifetime in-app purchase has not otherwise changed; we understand that it can be reviewed together with the corrected app binary.

Thank you.

## Reviewer test steps

1. Launch Local Voice and complete onboarding.
2. On the explanatory permission screen, choose **Continue**; macOS then displays its own microphone permission dialog.
3. Grant Accessibility permission in System Settings.
4. Open TextEdit, place the cursor in a document, and invoke the configured Local Voice dictation shortcut.
5. Speak and stop recording. The locally transcribed text is inserted at the active cursor as the direct result of that action.
6. Close the Local Voice main window.
7. Choose **Window → Open Local Voice** or press **Command-0**. The main window opens again.

## Submission checklist

- Update the subtitle in App Store Connect.
- Attach a short screen recording showing the user-initiated insertion and window reopening flow if App Review requests it.
- In Review Notes, state exactly where the dictation shortcut is shown and configured.
- Describe Accessibility as the concrete user-initiated text-insertion flow, not background automation.
- Verify the Lifetime in-app purchase is attached to the submitted app version.

## Risk note

This explanation is accurate and defensible, but it cannot guarantee approval. Apple may interpret Guideline 2.4.5 strictly and require removal of Accessibility from the Mac App Store build. If that happens again after reconsideration, the practical fallback is separate distribution behavior: full automatic insertion in the direct build and a different App Store interaction model.
