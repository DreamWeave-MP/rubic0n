#include <sol/sol.hpp>

#include <osg/Vec2f>
#include <osg/Vec3f>
#include <osg/Vec4f>

#include <array>
#include <chrono>
#include <cstddef>
#include <exception>
#include <iostream>
#include <string>
#include <tuple>
#include <utility>

#ifndef OPENMW_UDATA_DEFAULT_SCRIPT
#define OPENMW_UDATA_DEFAULT_SCRIPT "bench/openmw_userdata/workloads.lua"
#endif

namespace Harness
{
    using Vec2 = osg::Vec2f;
    using Vec3 = osg::Vec3f;
    using Vec4 = osg::Vec4f;

    struct PositionSource
    {
        Vec3 mPosition{ 11.f, 22.f, 33.f };
    };

    struct FinalizerProbe
    {
        explicit FinalizerProbe(int value)
            : mValue(value)
        {
        }

        FinalizerProbe(const FinalizerProbe&) = delete;
        FinalizerProbe& operator=(const FinalizerProbe&) = delete;
        FinalizerProbe(FinalizerProbe&& other) noexcept
            : mValue(other.mValue)
            , mArmed(std::exchange(other.mArmed, false))
        {
        }
        FinalizerProbe& operator=(FinalizerProbe&&) = delete;

        ~FinalizerProbe()
        {
            if (mArmed)
                ++sFinalized;
        }

        int mValue;
        bool mArmed = true;
        static inline std::size_t sFinalized = 0;
    };
}

// OpenMW disables Sol's automatic usertype enrollment for these immutable
// values and registers the supported operations explicitly.
namespace sol
{
    template <>
    struct is_automagical<Harness::Vec2> : std::false_type
    {
    };
    template <>
    struct is_automagical<Harness::Vec3> : std::false_type
    {
    };
    template <>
    struct is_automagical<Harness::Vec4> : std::false_type
    {
    };
    template <>
    struct is_automagical<Harness::PositionSource> : std::false_type
    {
    };
    template <>
    struct is_automagical<Harness::FinalizerProbe> : std::false_type
    {
    };
}

namespace
{
    using namespace Harness;

    template <typename T>
    float zero(const T&)
    {
        return 0.f;
    }

    template <typename T>
    float one(const T&)
    {
        return 1.f;
    }

    template <typename T, std::size_t I>
    float get(const T& value)
    {
        return value[I];
    }

    // This intentionally mirrors OpenMW's eager registration of every swizzle
    // permutation over vector components plus the constant components 0 and 1.
    template <typename T>
    void addSwizzleFields(sol::usertype<T>& type)
    {
        constexpr auto components = [] {
            std::array<std::pair<char, float (*)(const T&)>, T::num_components + 2> result{};
            result[T::num_components] = { '0', zero<T> };
            result[T::num_components + 1] = { '1', one<T> };
            if constexpr (T::num_components > 1)
            {
                result[0] = { 'x', get<T, 0> };
                result[1] = { 'y', get<T, 1> };
            }
            if constexpr (T::num_components > 2)
                result[2] = { 'z', get<T, 2> };
            if constexpr (T::num_components > 3)
                result[3] = { 'w', get<T, 3> };
            return result;
        }();

        for (const auto& first : components)
        {
            type[std::string{ first.first }]
                = sol::readonly_property([=](const T& value) { return first.second(value); });
            for (const auto& second : components)
            {
                type[std::string{ first.first, second.first }] = sol::readonly_property(
                    [=](const T& value) { return Vec2(first.second(value), second.second(value)); });
                for (const auto& third : components)
                {
                    type[std::string{ first.first, second.first, third.first }] = sol::readonly_property([=](const T& value) {
                        return Vec3(first.second(value), second.second(value), third.second(value));
                    });
                    for (const auto& fourth : components)
                    {
                        type[std::string{ first.first, second.first, third.first, fourth.first }]
                            = sol::readonly_property([=](const T& value) {
                                  return Vec4(first.second(value), second.second(value), third.second(value),
                                      fourth.second(value));
                              });
                    }
                }
            }
        }
    }

    template <typename T>
    void addVectorMethods(sol::usertype<T>& type)
    {
        type[sol::meta_function::unary_minus] = [](const T& value) { return -value; };
        type[sol::meta_function::addition] = [](const T& left, const T& right) { return left + right; };
        type[sol::meta_function::subtraction] = [](const T& left, const T& right) { return left - right; };
        type[sol::meta_function::equal_to] = [](const T& left, const T& right) { return left == right; };
        type[sol::meta_function::multiplication]
            = sol::overload([](const T& value, float scalar) { return value * scalar; },
                [](const T& left, const T& right) { return left * right; });
        type[sol::meta_function::division] = [](const T& value, float scalar) { return value / scalar; };
        type["dot"] = [](const T& left, const T right) { return left * right; };
        type["length"] = &T::length;
        type["length2"] = &T::length2;
        type["normalize"] = [](const T& value) {
            const float length = value.length();
            if (length == 0.f)
                return std::make_tuple(T(), 0.f);
            return std::make_tuple(value * (1.f / length), length);
        };
        type["emul"] = [](const T& left, const T& right) {
            T result;
            for (int i = 0; i < T::num_components; ++i)
                result[i] = left[i] * right[i];
            return result;
        };
        type["ediv"] = [](const T& left, const T& right) {
            T result;
            for (int i = 0; i < T::num_components; ++i)
                result[i] = left[i] / right[i];
            return result;
        };
        addSwizzleFields(type);
    }

    template <typename T>
    std::size_t userdataPayloadSize(lua_State* state, T value)
    {
        sol::stack::push(state, std::move(value));
        const std::size_t result = lua_objlen(state, -1);
        lua_pop(state, 1);
        return result;
    }

    template <typename T>
    bool hasZeroUpvalueCFinalizer(lua_State* state, T value)
    {
        sol::stack::push(state, std::move(value));
        bool valid = lua_getmetatable(state, -1) != 0;
        if (valid)
        {
            lua_getfield(state, -1, "__gc");
            valid = lua_iscfunction(state, -1) != 0;
            if (valid)
            {
                const char* upvalue = lua_getupvalue(state, -1, 1);
                valid = upvalue == nullptr;
                if (upvalue != nullptr)
                    lua_pop(state, 1);
            }
            lua_pop(state, 1); // __gc
            lua_pop(state, 1); // metatable
        }
        lua_pop(state, 1); // userdata
        return valid;
    }

    void registerBindings(sol::state& lua)
    {
        sol::table util(lua, sol::create);

        util["vector2"] = [](float x, float y) { return Vec2(x, y); };
        sol::usertype<Vec2> vec2 = lua.new_usertype<Vec2>("Vec2");
        addVectorMethods(vec2);

        util["vector3"] = [](float x, float y, float z) { return Vec3(x, y, z); };
        sol::usertype<Vec3> vec3 = lua.new_usertype<Vec3>("Vec3");
        addVectorMethods(vec3);
        vec3[sol::meta_function::involution] = [](const Vec3& left, const Vec3& right) { return left ^ right; };
        vec3["cross"] = [](const Vec3& left, const Vec3& right) { return left ^ right; };

        util["vector4"] = [](float x, float y, float z, float w) { return Vec4(x, y, z, w); };
        sol::usertype<Vec4> vec4 = lua.new_usertype<Vec4>("Vec4");
        addVectorMethods(vec4);

        lua["util"] = util;

        sol::usertype<PositionSource> sourceType = lua.new_usertype<PositionSource>("PositionSource", sol::no_constructor);
        sourceType["position"] = sol::readonly_property([](const PositionSource& source) { return source.mPosition; });
        sourceType["samplePosition"] = [](const PositionSource& source, float offset) {
            return source.mPosition + Vec3(offset, -offset * 0.5f, offset * 0.25f);
        };
        lua["source"] = PositionSource{};

        sol::usertype<FinalizerProbe> probeType
            = lua.new_usertype<FinalizerProbe>("FinalizerProbe", sol::no_constructor);
        probeType["value"] = sol::readonly(&FinalizerProbe::mValue);

        sol::table bench(lua, sol::create);
        bench["now"] = [] {
            using Clock = std::chrono::steady_clock;
            return std::chrono::duration<double>(Clock::now().time_since_epoch()).count();
        };
        bench["cpp_vec2_size"] = sizeof(Vec2);
        bench["cpp_vec3_size"] = sizeof(Vec3);
        bench["cpp_vec4_size"] = sizeof(Vec4);
        bench["userdata_vec2_payload"] = userdataPayloadSize(lua.lua_state(), Vec2{});
        bench["userdata_vec3_payload"] = userdataPayloadSize(lua.lua_state(), Vec3{});
        bench["userdata_vec4_payload"] = userdataPayloadSize(lua.lua_state(), Vec4{});
        bench["vector_finalizer_is_zero_upvalue_cfunc"] = hasZeroUpvalueCFinalizer(lua.lua_state(), Vec3{});
        bench["new_finalizer_probe"] = [](int value) { return FinalizerProbe(value); };
        bench["reset_finalizer_probe"] = [] { FinalizerProbe::sFinalized = 0; };
        bench["finalizer_probe_count"] = [] { return FinalizerProbe::sFinalized; };
        lua["bench"] = bench;
    }

    void setArguments(sol::state& lua, int argc, char** argv)
    {
        sol::table args(lua, sol::create);
        args[0] = OPENMW_UDATA_DEFAULT_SCRIPT;
        for (int i = 1; i < argc; ++i)
            args[i] = argv[i];
        lua["arg"] = args;
    }
}

int main(int argc, char** argv)
{
    try
    {
        sol::state lua;
        lua.open_libraries(sol::lib::base, sol::lib::math, sol::lib::table, sol::lib::string, sol::lib::io,
            sol::lib::os, sol::lib::package, sol::lib::jit);
        registerBindings(lua);
        setArguments(lua, argc, argv);
        const sol::protected_function_result result = lua.safe_script_file(OPENMW_UDATA_DEFAULT_SCRIPT);
        if (!result.valid())
        {
            const sol::error error = result;
            std::cerr << "openmw userdata benchmark: " << error.what() << '\n';
            return 1;
        }
        return 0;
    }
    catch (const std::exception& error)
    {
        std::cerr << "openmw userdata benchmark: " << error.what() << '\n';
        return 1;
    }
}
