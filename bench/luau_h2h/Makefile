CC ?= cc
CXX ?= c++
LUAJIT_ROOT ?= ../..
LUAU_ROOT ?= ../../../luau
BUILD_DIR ?= build
CFLAGS ?= -O2 -DNDEBUG
CXXFLAGS ?= -O2 -DNDEBUG
LUAJIT_LIB := $(LUAJIT_ROOT)/src/libluajit.a
LUAU_SOURCES := $(wildcard $(LUAU_ROOT)/VM/src/*.cpp)
LUAU_OBJECTS := $(patsubst $(LUAU_ROOT)/VM/src/%.cpp,$(BUILD_DIR)/luau/%.o,$(LUAU_SOURCES))
LUAU_INCLUDES := -I$(LUAU_ROOT)/VM/include -I$(LUAU_ROOT)/Common/include

.PHONY: all luajit luau run clean

all: luajit luau

luajit: $(BUILD_DIR)/h2h_luajit

luau: $(BUILD_DIR)/h2h_luau $(BUILD_DIR)/h2h_luau_onecall

$(BUILD_DIR)/h2h_luajit: h2h_luajit.c h2h.h h2h_main.h $(LUAJIT_LIB) | $(BUILD_DIR)
	$(CC) $(CFLAGS) -I$(LUAJIT_ROOT)/src -o $@ h2h_luajit.c $(LUAJIT_LIB) -lm -ldl

$(BUILD_DIR)/luau/%.o: $(LUAU_ROOT)/VM/src/%.cpp | $(BUILD_DIR)/luau
	$(CXX) -std=c++17 $(CXXFLAGS) -fno-math-errno $(LUAU_INCLUDES) -c -o $@ $<

$(BUILD_DIR)/h2h_luau: h2h_luau.cpp h2h.h h2h_main.h $(LUAU_OBJECTS)
	$(CXX) -std=c++17 $(CXXFLAGS) $(LUAU_INCLUDES) -o $@ h2h_luau.cpp $(LUAU_OBJECTS)

$(BUILD_DIR)/h2h_luau_onecall: h2h_luau.cpp h2h.h h2h_main.h $(LUAU_OBJECTS)
	$(CXX) -std=c++17 $(CXXFLAGS) -DH2H_ONECALL $(LUAU_INCLUDES) -o $@ h2h_luau.cpp $(LUAU_OBJECTS)

$(BUILD_DIR) $(BUILD_DIR)/luau:
	mkdir -p $@

run: all
	$(BUILD_DIR)/h2h_luau 20000 101
	$(BUILD_DIR)/h2h_luajit 20000 101
	$(BUILD_DIR)/h2h_luau 200000 101
	$(BUILD_DIR)/h2h_luajit 200000 101

clean:
	rm -rf $(BUILD_DIR)
