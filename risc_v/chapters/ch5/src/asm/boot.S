# boot.S
# bootloader for SoS
# Stephen Marz
# 8 February 2019

# Disable generation of compressed instructions.
.option norvc

# Define a .text.init section. The .text.init is put at the
# starting address so that the entry _start is put at the RISC-V
# address 0x8000_0000.
.section .text.init
.equ DATA_BASE,   0xffffffff
# Execution starts here.
.global _start
_start:

	# Disable linker instruction relaxation for the `la` instruction below.
	# This disallows the assembler from assuming that `gp` is already initialized.
	# This causes the value stored in `gp` to be calculated from `pc`.
	# The job of the global pointer is to give the linker the ability to address
	# memory relative to GP instead of as an absolute address.
.option push
.option norelax
	la		gp, _global_pointer
.option pop
	# SATP should be zero, but let's make sure. Each HART has its own
	# SATP register.
	csrw	satp, zero
	# Any hardware threads (hart) that are not bootstrapping
	# need to wait for an IPI
	csrr	t0, mhartid
	bnez	t0, 3f

	# Set all bytes in the BSS section to zero.
	la 		a0, _bss_start
	la		a1, _bss_end
	bgeu	a0, a1, 2f
1:
	sd		zero, (a0)
	addi	a0, a0, 8
	bltu	a0, a1, 1b
2:
	# The stack grows from bottom to top, so we put the stack pointer
	# to the very end of the stack range.
	la		sp, _stack_end
	# Setting `mstatus` register:
	# 0b01 << 11: Machine's previous protection mode is 2 (MPP=2).
	li		t0, 0b11 << 11
	csrw	mstatus, t0
	# Do not allow interrupts while running kinit
	csrw	mie, zero
	# Machine's exception program counter (MEPC) is set to `kinit`.
	la		t1, kinit
	csrw	mepc, t1
	# Set the return address to get us into supervisor mode
	la		ra, 2f
	# We use mret here so that the mstatus register is properly updated.
	mret
2:
	li  t0, DATA_BASE  # Load the base address into t0

	# Configure pmpaddr1 (assuming we use the second PMP entry)
	csrw pmpaddr0, t0

	# Configure pmpcfg0 for entry 1 (assuming entry 1 is the second one in pmpcfg0)
	# Mode: NAPOT (11)
	# Permissions: Read (1), Write (1), Execute (0) -> RW = 11 = 3
	# pmpcfg0 bits for entry 1: [... (entry 0) | L|X|W|R|A1|A0 | ... (other entries)]
	# Assuming each pmpcfg register controls 8 entries and each entry config is 8 bits
	# Entry 1 starts at bit position 8 (8 bits * 1 entry offset)
	li  t1, 0b00011111  # L=0, X=0, W=1, R=1, A=NAPOT(11)
	// slli t1, t1, 8     # Shift left to position it for entry 1
	csrw pmpcfg0, t1

	# We set the return address (ra above) to this label. When kinit() is finished
	# in Rust, it will return here.

	# Setting `mstatus` (supervisor status) register:
	# 0b01 << 11 : Previous protection mode is 1 (MPP=01 [Supervisor]).
	# 1 << 7     : Previous machine interrupt-enable bit is 1 (MPIE=1 [Enabled])
	# 1 << 5     : Previous interrupt-enable bit is 1 (SPIE=1 [Enabled]).
	# We set the "previous" bits because the mret will write the current bits
	# with the previous bits.
	li		t0, (0b01 << 11) | (1 << 7) | (1 << 5)
	csrw	mstatus, t0
	# Machine's trap vector base address is set to `m_trap_vector`, for
	# "machine" trap vector.
	la		t2, m_trap_vector
	csrw	mtvec, t2
	# Setting `stvec` (supervisor trap vector) register:
	# Essentially this is a function pointer, but the last two bits can be 00 or 01
	# 00        : All exceptions set pc to BASE
	# 01        : Asynchronous interrupts set pc to BASE + 4 x scause
	# la		t3, s_trap_vector
	# csrw	stvec, t3
	# Jump to kmain. We put the MPP = 01 for supervisor mode, so after
	# mret, we will jump to kmain in supervisor mode.
	la		t1, kmain
	csrw	mepc, t1
	# Setting `sie` (supervisor interrupt enable) register:
	# This register takes the same bits as mideleg
	# 1 << 1    : Supervisor software interrupt enable (SSIE=1 [Enabled])
	# 1 << 5    : Supervisor timer interrupt enable (STIE=1 [Enabled])
	# 1 << 9    : Supervisor external interrupt enable (SEIE=1 [Enabled])
	# 0xaaa = MEIP/SEIP and MTIP/STIP and MSIP/SSIP
	li		t2, 0xaaa
	csrw	mie, t2
	la		ra, 4f
	mret
3:

	# Parked harts go here. We need to set these
	# to only awaken if it receives a software interrupt,
	# which we're going to call the SIPI (Software Intra-Processor Interrupt).
	# We call the SIPI by writing the software interrupt into the Core Local Interruptor (CLINT)
	# Which is calculated by: base_address + hart * 4
	# where base address is 0x0200_0000 (MMIO CLINT base address)
	# We only use additional harts to run user-space programs, although this may
	# change.

	# We divide up the stack so the harts aren't clobbering one another.
	la		sp, _stack_end
	li		t0, 0x10000
	csrr	a0, mhartid
	mul		t0, t0, a0
	sub		sp, sp, t0

	# The parked harts will be put into machine mode with interrupts enabled.
	li		t0, 0b11 << 11 | (1 << 7)
	csrw	mstatus, t0
	# Allow for MSIP (Software interrupt). We will write the MSIP from hart #0 to
	# awaken these parked harts.
	li		t3, (1 << 3)
	csrw	mie, t3
	# Machine's exception program counter (MEPC) is set to the Rust initialization
	# code and waiting loop.
	la		t1, kinit_hart
	csrw	mepc, t1
	# Machine's trap vector base address is set to `m_trap_vector`, for
	# "machine" trap vector. The Rust initialization routines will give each
	# hart its own trap frame. We can use the same trap function and distinguish
	# between each hart by looking at the trap frame.
	la		t2, m_trap_vector
	csrw	mtvec, t2
	# Whenever our hart is done initializing, we want it to return to the waiting
	# loop, which is just below mret.
	la		ra, 4f
	# We use mret here so that the mstatus register is properly updated.
	mret

4:
	# wfi = wait for interrupt. This is a hint to the harts to shut everything needed
	# down. However, the RISC-V specification allows for wfi to do nothing. Anyway,
	# with QEMU, this will save some CPU!
	wfi
	j		4b


