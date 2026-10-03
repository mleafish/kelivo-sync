# Real-time S3 sync between devices

Kelivo keeps its data in a local SQLite database. This fork adds an optional
layer that keeps two or more installs of the app converging through one S3
bucket, so a conversation written on an iPhone shows up on a Windows PC (or the
other way round) without anyone pressing a button.

This is separate from **S3 Backup** on the same settings screen. Backup writes
dated archives you restore by hand; sync maintains one live snapshot per device
and reconciles them continuously.

## Enabling it

1. Fill in **S3 Settings** (endpoint, region, bucket, keys, prefix) on the
   backup settings screen. Sync reuses that connection — there is nothing to
   configure twice.
2. Open **Auto Sync** and turn on *Enable auto sync*.
3. Give the device a name ("iPhone", "Work PC") so the other side can tell the
   snapshots apart, and optionally change how often it checks for changes.
4. Repeat on the second device with the same S3 settings and a different
   device name.

The first device to sync uploads its snapshot. A second device that has no
conversations of its own adopts that snapshot on its first pass, so setting up a
new install does not require moving a backup file by hand.

## What it stores

```
<prefix>/sync/devices/<deviceId>.zip    snapshot of that device's data
<prefix>/sync/devices/<deviceId>.json   who it is and when it last changed
```

`<deviceId>` is a UUID assigned to the install the first time sync is turned on.
Nothing under `sync/` appears in the backup restore list.

## How a pass works

Every tick (20 seconds by default, and immediately when the app returns to the
foreground) a device:

1. lists the other devices' sidecars;
2. for each snapshot newer than the last one it applied, downloads it and
   reconciles it into the live database;
3. republishes its own snapshot if the local database changed.

Local changes are detected by the size and mtime of the database file, so every
write counts and no code path has to remember to notify the sync engine. What a
device has already published is remembered as the signature the file had at
upload time; applying a remote snapshot changes that file, which makes the next
comparison differ and republishes the reconciled result. That one comparison is
what makes the loop settle instead of ping-ponging.

## Reconciling two devices

Applying a snapshot goes through the existing merge path, which is the only one
that takes effect immediately — an overwrite restore is staged and only lands on
the next launch.

Within that merge, conversations are settled by `updated_at`:

- only one side has the conversation → it is imported;
- both sides have it, identical → nothing to do;
- both sides have it, different → the newer one wins, in place, keeping the same
  conversation id.

That last rule is what stops a second device from accumulating a duplicate copy
of a conversation every time the other device appends a message.

Deletions propagate too: `deleteConversation` has always written a tombstone
row, and the merge now reads those from the other device's snapshot. A
conversation edited locally *after* the remote delete survives, so a delete does
not silently discard newer work.

## Limits worth knowing

- **Last writer wins.** If both devices edit the same conversation between two
  syncs, the older edit is discarded. Before a device reconciles anything it
  uploads its own state first, so the losing side is at least still present in
  that device's published snapshot.
- **Which side is "newer" comes from each device's own clock**, because
  `conversation_rows.updated_at` is written locally when a message is appended.
  Two devices whose clocks disagree by more than the gap between edits can
  therefore settle a conversation the wrong way. Phone and desktop clocks are
  normally NTP-synced to well under a second, so this only matters if a clock is
  badly wrong.
- **Sync is foreground-only on iOS.** The system suspends the periodic timer
  while the app is in the background; a pass runs as soon as it is reopened.
- **Attachments are opt-in.** *Include files and images* off (the default) keeps
  snapshots to the database alone. With it on, assets are copied additively and
  snapshots get much larger.
