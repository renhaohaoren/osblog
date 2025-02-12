# trap.S
# In the future our trap vector will go here.

.global asm_trap_vector
# This will be our trap vector when we start
# handling interrupts.
asm_trap_vector:
	// li		t0, (0b11 << 11) | (1 << 7) | (1 << 3)
	// csrw	mstatus, t0
	mret

