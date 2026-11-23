.text
.globl _start
_start:
 adrp x0, msg
 add x0, x0, :lo12:msg
 bl helper
 ret
