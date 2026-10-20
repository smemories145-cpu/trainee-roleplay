# STARLIGHT RP — Illness & Hospital QA Checklist

This is a manual checklist for the draft hospital migration. Do **not** merge/deploy until these checks pass on a backed-up staging/test dataset.

## Training and illness
- [ ] Practice the same skill 9 times in one Bangkok calendar day: no illness warning yet.
- [ ] Attempt 10 for that skill: training succeeds and shows the warning.
- [ ] Attempt 11 for that skill: training succeeds, the character becomes sick, and the UI refreshes the sick status.
- [ ] Attempt 12 for the same skill that day: blocked.
- [ ] A different skill has a separate count; a different character has a separate count.
- [ ] After the Bangkok day changes, counts reset for the new day.
- [ ] Training through a thread's skill selector shares the same per-character/per-skill counter.
- [ ] A sick character cannot train until cured.
- [ ] Admin/manual sickness controls work only for admin or `manage_characters`.
- [ ] Unmarked threads never trigger sickness automatically; a staff-marked activity thread marks the posting character sick only after a valid post succeeds.
- [ ] A normal character edit cannot clear `sick`, reset `practiceCounts`, or alter the saved stage/timer; trusted RPCs still work.
- [ ] Generic post editing cannot fake hospital annotations/training flags, and players cannot delete posts linked to the treatment history.

## Queue assignment
- [ ] A non-sick character cannot receive a queue.
- [ ] Invalid URL, post from another character, post from another account, wrong thread, missing `รับบัตรคิว` note, and 70-or-fewer whitespace-separated words are rejected without creating a queue.
- [ ] Valid queue post in the hospital reception thread gets exactly one queue.
- [ ] Room selection is 1, 2, or 3 only, mapped respectively to คุณหมอลี, คุณหมอจาง, คุณหมอชิม.
- [ ] Green assignment text appears below the post while the original roleplay text remains unchanged.
- [ ] Submitting the same queue-post link again does not allocate a second queue.
- [ ] A second active queue/treatment for the same character is rejected.

## Payment and medicine
- [ ] Wrong-room post, wrong note (`รับการรักษา`), invalid character/account, or 70-or-fewer whitespace-separated words are rejected.
- [ ] Cash below 1,000 won: no deduction and no medicine.
- [ ] Cash payment: exactly 1,000 won deducted, one medicine item added, payment annotation shown below the treatment post.
- [ ] Bank balance below 1,000 won: no bank deduction and no medicine.
- [ ] Bank payment: exactly 1,000 won deducted, one transaction recorded, and one medicine item added.
- [ ] Repeat submission/payment for the same treatment does not charge twice or add another item.
- [ ] Medicine used before (or at) the 3-hour expiry cures the character, consumes only the matching bottle, and restores the saved stage.
- [ ] Medicine used after expiry is consumed, but the character remains sick and the stage is not restored.
- [ ] Submitting a new queue after expiry clears the expired queue/medicine and permits a new 1,000-won payment and new 3-hour timer.
- [ ] Medicine is hidden from both regular shops and cannot be purchased for free.

## UI and regression
- [ ] The bottle PNG loads in character inventory and phone inventory.
- [ ] The use-medicine action is visible only to the character owner.
- [ ] Check pop-ups, error messages, phone inventory, and profile inventory on desktop and mobile.
- [ ] Recheck bank deposit/withdraw/transfer, normal store purchases, forum posting, character rank, and existing inventory data.
