CXX ?= c++
LUAJIT_ROOT ?= ../..
OPENMW_ROOT ?= ../../../openmw
BUILD_DIR ?= build
TARGET := $(BUILD_DIR)/openmw_userdata_bench
SOURCE := openmw_userdata_bench.cpp
WORKLOAD := $(CURDIR)/workloads.lua
LUAJIT_LIB := $(LUAJIT_ROOT)/src/libluajit.a

CPPFLAGS += \
	-I$(OPENMW_ROOT)/extern/sol_config \
	-I$(OPENMW_ROOT)/extern/sol3 \
	-I$(OPENMW_ROOT)/OpenSceneGraph/include \
	-I$(LUAJIT_ROOT)/src \
	-DOPENMW_UDATA_DEFAULT_SCRIPT=\"$(WORKLOAD)\"
CXXFLAGS ?= -O3 -DNDEBUG
CXXFLAGS += -std=c++20 -Wall -Wextra -Wpedantic
LDLIBS += $(LUAJIT_LIB) -lm -ldl

.PHONY: all clean run self-test

all: $(TARGET)

$(TARGET): $(SOURCE) $(WORKLOAD) $(LUAJIT_LIB) Makefile | $(BUILD_DIR)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(LDFLAGS) -o $@ $(SOURCE) $(LDLIBS)

$(BUILD_DIR):
	mkdir -p $@

run: $(TARGET)
	$(TARGET) --iterations 10000 --bursts 20

self-test: $(TARGET)
	$(TARGET) --self-test

clean:
	rm -rf $(BUILD_DIR)
