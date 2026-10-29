--!strict
--[[
	Game-wide settings. Everything tweakable lives here.
]]

local Config = {
	-- Name shown in the firmware, boot screens and docs.
	OS_NAME = "Brick Linux",

	---------------------------------------------------------------------------
	-- Computers
	---------------------------------------------------------------------------

	-- Guest RAM per computer. Each running computer holds this much in server memory.
	RAM_MB = 32,
	-- Disk size per player. Only written blocks use memory/DataStore space.
	DISK_MB = 32,
	-- Terminal size (the guest is told this through the kernel command line).
	COLS = 80,
	ROWS = 25,

	-- Server CPU time (seconds) all running computers may use per frame, and the
	-- most a single computer may take. Idle computers cost almost nothing. With
	-- one player per server there's one computer, so it gets most of a frame
	-- (about 18 MIPS with native code generation); keep some room for the rest
	-- of the game.
	FRAME_BUDGET = 0.010,
	MAX_COMPUTER_BUDGET = 0.010,
	-- Guest microseconds that pass per executed instruction while busy (see Machine).
	US_PER_INSTRUCTION = 0.25,

	-- Seconds the firmware waits before booting the default entry.
	BOOT_COUNTDOWN = 3,

	-- Kernel image in ServerStorage.LinuxImages (built by CI from linux/). It
	-- boots both the installed system and the live installer on the flash drive.
	IMAGE = "BrickLinux",

	-- The live installer only boots from the installer flash drive, which the
	-- game plugs into a desk (desk attribute "FlashDrive", or
	-- ComputerService.insertFlashDrive). Set to false to make it always
	-- available, e.g. for testing in Studio before the flash drive exists.
	REQUIRE_FLASH_DRIVE = true,

	---------------------------------------------------------------------------
	-- Screens and moderation
	---------------------------------------------------------------------------

	-- When false, only the person using a computer sees its screen; others see
	-- "in use". Terminal text is player-generated and unfiltered, so Roblox's
	-- text filtering rules apply before turning this on (see docs/MODERATION.md).
	SHOW_SCREENS_TO_OTHERS = false,

	-- Raw output per computer per frame before the server switches to sending
	-- compact screen snapshots (protects bandwidth when something floods output).
	MAX_STREAM_BYTES_PER_FRAME = 4096,
	SNAPSHOT_INTERVAL = 0.1,

	-- Input from clients: max bytes per message and messages per second.
	MAX_INPUT_BYTES = 512,
	MAX_INPUT_RATE = 60,

	---------------------------------------------------------------------------
	-- Saving
	---------------------------------------------------------------------------

	DISK_DATASTORE = "BrickDisks_v1",
	-- Autosave changed disks this often (seconds), and at most this often on `sync`.
	AUTOSAVE_INTERVAL = 120,
	MIN_SAVE_INTERVAL = 20,

	---------------------------------------------------------------------------
	-- Community Workshop
	---------------------------------------------------------------------------

	WORKSHOP_DATASTORE = "BrickWorkshop_v1",
	-- Largest package (uncompressed tar) a player may publish.
	MAX_PACKAGE_BYTES = 1024 * 1024,
	-- Run package names/descriptions/readmes through TextService before others see them.
	FILTER_WORKSHOP_TEXT = true,
	-- How many packages one player may publish.
	MAX_PACKAGES_PER_PLAYER = 50,

	---------------------------------------------------------------------------
	-- In-game network
	---------------------------------------------------------------------------

	-- Computers get 10.0.x.y addresses; the game itself answers at 10.0.0.1
	-- (ping, DNS for player computer names).
	GATEWAY_IP = "10.0.0.1",
	DNS_SUFFIX = "brick",
	-- Frames per second one computer may send before the switch drops them.
	MAX_FRAMES_PER_SECOND = 400,
	-- Each server has one player, so other players' computers are in other
	-- servers. Packets to them go out in MessagingService messages (several per
	-- message, up to this many messages per second; MessagingService allows a
	-- one-player server 14/s and `msg` needs a few). The directory of online
	-- computers is a MemoryStore sorted map.
	RELAY_MESSAGES_PER_SECOND = 10,
	NET_DIRECTORY = "BrickNet_v1",
}

return Config
