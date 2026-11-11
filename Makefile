# cocotb + Icarus Verilog flow.  Usage:
#   make                         v1: APB systolic array (sa_apb_top) tests
#   make mlp                     v2: DLRM MLP layer engine (mlp_top: AXI4 DMA + requant) tests
#   make SEED=123 NUM_ITERS=500  pick seed / iteration count
#   make DEFINES=BUG_SKEW        inject a bug (testbench must FAIL)
#   make mlp DEFINES=BUG_4K      inject an MLP bug
#   make N=8                     different array size
SIM          ?= icarus
TOPLEVEL_LANG = verilog
TOP          ?= sa_apb_top
N            ?= 4
DEFINES      ?=
SEED         ?=
SIM_BUILD    ?= sim_build_$(TOP)_n$(N)$(if $(DEFINES),_$(DEFINES))
VERILOG_SOURCES = $(wildcard $(PWD)/rtl/*.v)
COCOTB_TOPLEVEL = $(TOP)
COCOTB_TEST_MODULES = $(if $(filter mlp_top,$(TOP)),test_mlp,test_systolic)
export PYTHONPATH := $(PWD)/tb:$(PYTHONPATH)
COMPILE_ARGS += -g2005 -P$(TOP).N=$(N) $(addprefix -D,$(DEFINES))
ifneq ($(SEED),)
export COCOTB_RANDOM_SEED = $(SEED)
export RANDOM_SEED = $(SEED)
endif
include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: mlp
mlp:
	$(MAKE) TOP=mlp_top SIM_BUILD=sim_build_mlp_top_n$(N)$(if $(DEFINES),_$(DEFINES))

clean::
	rm -rf sim_build* results results.xml __pycache__ tb/__pycache__
