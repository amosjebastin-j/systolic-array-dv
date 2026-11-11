# cocotb + Icarus Verilog flow.  Usage:
#   make                         run all tests (default seed)
#   make SEED=123 NUM_ITERS=500  pick seed / iteration count
#   make DEFINES=BUG_SKEW        inject a bug (testbench must FAIL)
#   make N=8                     different array size
SIM          ?= icarus
TOPLEVEL_LANG = verilog
N            ?= 4
DEFINES      ?=
SEED         ?=
VERILOG_SOURCES = $(wildcard $(PWD)/rtl/*.v)
COCOTB_TOPLEVEL = sa_apb_top
COCOTB_TEST_MODULES = test_systolic
export PYTHONPATH := $(PWD)/tb:$(PYTHONPATH)
COMPILE_ARGS += -g2005 -Psa_apb_top.N=$(N) $(addprefix -D,$(DEFINES))
ifneq ($(SEED),)
export COCOTB_RANDOM_SEED = $(SEED)
export RANDOM_SEED = $(SEED)
endif
include $(shell cocotb-config --makefiles)/Makefile.sim

clean::
	rm -rf sim_build* results results.xml __pycache__ tb/__pycache__
