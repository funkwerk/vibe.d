/**
	Defines a string based multi-map with conserved insertion order.

	Copyright: © 2012-2014 RejectedSoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.utils.dictionarylist;

import vibe.utils.array : removeFromArrayIdx;
import vibe.utils.string : icmp2;
import std.exception : enforce;


/**
	Behaves similar to $(D VALUE[string]) but the insertion order is not changed
	and multiple values per key are supported.

	This kind of map is used for MIME headers (e.g. for HTTP, see
	vibe.inet.message.InetHeaderMap), or for form data
	(vibe.inet.webform.FormFields). Note that the map can contain fields with
	the same key multiple times if addField is used for insertion. Insertion
	order is preserved.

	Note that despite case not being relevant for matching keyse, iterating
	over the map will yield	the original case of the key that was put in.

	Insertion and lookup has O(n) complexity.
*/
struct DictionaryList(VALUE, bool case_sensitive = true, size_t NUM_STATIC_FIELDS = 32, bool USE_HASHSUM = false) {
	import std.typecons : Tuple;

	private {
		static struct Field {
			static if (USE_HASHSUM) uint keyCheckSum;
			else {
				enum keyCheckSum = 0;
				this(uint, string key, VALUE value) { this.key = key; this.value = value; }
			}
			string key;
			VALUE value;
			Tuple!(string, ValueType) toTuple() { return Tuple!(string, ValueType)(key, value); }
			Tuple!(string, const(ValueType)) toTuple() const { return Tuple!(string, const(ValueType))(key, value); }
		}
		Field[NUM_STATIC_FIELDS] m_fields;
		size_t m_fieldCount = 0;
		Field[] m_extendedFields;

		enum bool safeValueCopy = __traits(compiles, (VALUE v) @safe { VALUE vc; vc = v; });
	}

	alias ValueType = VALUE;

	struct FieldTuple { string key; ValueType value; }

	/** The number of fields present in the map.
	*/
	@property size_t length() const { return m_fieldCount + m_extendedFields.length; }

	/// Supports serialization using vibe.data.serialization.
	static DictionaryList fromRepresentation(FieldTuple[] array)
	{
		DictionaryList ret;
		foreach (ref v; array) ret.addField(v.key, v.value);
		return ret;
	}
	/// ditto
	FieldTuple[] toRepresentation() {
		FieldTuple[] ret;
		foreach (k, ref v; this) ret ~= FieldTuple(k, v);
		return ret;
	}

	/** Removes the first field that matches the given key.
	*/
	void remove(string key)
	{
		static if (USE_HASHSUM) auto keysum = computeCheckSumI(key);
		enum keysum = 0;
		auto idx = getIndex(m_fields[0 .. m_fieldCount], key, keysum);
		if( idx >= 0 ){
			auto slice = m_fields[0 .. m_fieldCount];
			removeFromArrayIdx(slice, idx);
			m_fieldCount--;
		} else {
			idx = getIndex(m_extendedFields, key, keysum);
			enforce(idx >= 0);
			removeFromArrayIdx(m_extendedFields, idx);
		}
	}

	/** Removes all fields that matches the given key.
	*/
	void removeAll(string key)
	{
		static if (USE_HASHSUM) auto keysum = computeCheckSumI(key);
		else enum keysum = 0;
		for (size_t i = 0; i < m_fieldCount;) {
			if (m_fields[i].keyCheckSum == keysum && matches(m_fields[i].key, key)) {
				auto slice = m_fields[0 .. m_fieldCount];
				removeFromArrayIdx(slice, i);
				m_fieldCount--;
			} else i++;
		}

		for (size_t i = 0; i < m_extendedFields.length;) {
			if (m_fields[i].keyCheckSum == keysum && matches(m_fields[i].key, key))
				removeFromArrayIdx(m_extendedFields, i);
			else i++;
		}
	}

	/** Adds a new field to the map.

		The new field will be added regardless of any existing fields that
		have the same key, possibly resulting in duplicates. Use opIndexAssign
		if you want to avoid duplicates.
	*/
	void addField(string key, ValueType value)
	{
		static if (USE_HASHSUM) auto keysum = computeCheckSumI(key);
		else enum keysum = 0;
		if (m_fieldCount < m_fields.length)
			m_fields[m_fieldCount++] = Field(keysum, key, value);
		else m_extendedFields ~= Field(keysum, key, value);
	}

	/** Returns the first field that matches the given key.

		If no field is found, def_val is returned.
	*/
	inout(ValueType) get(string key, lazy inout(ValueType) def_val = ValueType.init)
	inout {
		if (auto pv = key in this) return *pv;
		return def_val;
	}

	/** Returns all values matching the given key.

		Note that the version returning an array will allocate for each call.
	*/
	const(ValueType)[] getAll(string key)
	const @trusted { // appender
		import std.array;
		auto ret = appender!(const(ValueType)[])();
		getAll(key, (v) @trusted { ret.put(v); });
		return ret.data;
	}
	/// ditto
	void getAll(string key, scope void delegate(const(ValueType)) @safe del)
	const {
		static if (USE_HASHSUM) uint keysum = computeCheckSumI(key);
		else enum keysum = 0;
		foreach (ref f; m_fields[0 .. m_fieldCount]) {
			static if (USE_HASHSUM)
				if (f.keyCheckSum != keysum) continue;
			if (matches(f.key, key)) del(f.value);
		}
		foreach (ref f; m_extendedFields) {
			static if (USE_HASHSUM)
				if (f.keyCheckSum != keysum) continue;
			if (matches(f.key, key)) del(f.value);
		}
	}

	/** Returns the first value matching the given key.
	*/
	inout(ValueType) opIndex(string key)
	inout {
		auto pitm = key in this;
		enforce(pitm !is null, "Accessing non-existent key '"~key~"'.");
		return *pitm;
	}

	/** Adds or replaces the given field with a new value.
	*/
	ValueType opIndexAssign(ValueType val, string key)
	{
		static if (USE_HASHSUM) auto keysum = computeCheckSumI(key);
		else enum keysum = 0;
		auto pitm = key in this;
		if (pitm) *pitm = val;
		else if (m_fieldCount < m_fields.length) m_fields[m_fieldCount++] = Field(keysum, key, val);
		else m_extendedFields ~= Field(keysum, key, val);
		return val;
	}

	/** Returns a pointer to the first field that matches the given key.
	*/
	inout(ValueType)* opBinaryRight(string op)(string key) inout if(op == "in")
	{
		static if (USE_HASHSUM) uint keysum = computeCheckSumI(key);
		else enum keysum = 0;
		auto idx = getIndex(m_fields[0 .. m_fieldCount], key, keysum);
		if( idx >= 0 ) return &m_fields[idx].value;
		idx = getIndex(m_extendedFields, key, keysum);
		if( idx >= 0 ) return &m_extendedFields[idx].value;
		return null;
	}
	/// ditto
	bool opBinaryRight(string op)(string key) inout if(op == "!in") {
		return !(key in this);
	}

	/** Iterates over all fields, including duplicates.
	*/
	auto byKey() inout { import std.algorithm.iteration : map; return byPair().map!(p => p[0]); }
	auto byValue() inout { import std.algorithm.iteration : map; return byPair().map!(p => p[1]); }

	auto byPair()
	{
		static struct Rng {
			DictionaryList* list;
			size_t idx;

			@property bool empty() const { return idx >= list.length; }
			@property Tuple!(string, ValueType) front() {
				if (idx < list.m_fieldCount)
					return list.m_fields[idx].toTuple;
				return list.m_extendedFields[idx - list.m_fieldCount].toTuple;
			}
			void popFront() { idx++; }
		}
		return Rng(&this, 0);
	}

	auto byPair()
	const {
		static struct Rng {
			const(DictionaryList)* list;
			size_t idx;

			@property bool empty() const { return idx >= list.length; }
			@property Tuple!(string, const(ValueType)) front() {
				if (idx < list.m_fieldCount)
					return list.m_fields[idx].toTuple;
				return list.m_extendedFields[idx - list.m_fieldCount].toTuple;
			}
			void popFront() { idx++; }
		}
		return Rng(&this, 0);
	}

	// Enables foreach iteration over a `DictionaryList` with two loop variables.
	alias byPair this;

	static if (is(typeof({ const(ValueType) v; ValueType w; w = v; }))) {
		/** Duplicates the header map.
		*/
		@property DictionaryList dup()
		const {
			DictionaryList ret;
			ret.m_fields[0 .. m_fieldCount] = m_fields[0 .. m_fieldCount];
			ret.m_fieldCount = m_fieldCount;
			ret.m_extendedFields = m_extendedFields.dup;
			return ret;
		}
	}

	private ptrdiff_t getIndex(in Field[] map, string key, uint keysum)
	const {
		foreach (i, ref const(Field) entry; map) {
			static if (USE_HASHSUM) if (entry.keyCheckSum != keysum) continue;
			if (matches(entry.key, key)) return i;
		}
		return -1;
	}

	private static bool matches(string a, string b)
	{
		static if (case_sensitive) return a == b;
		else return a.length == b.length && icmp2(a, b) == 0;
	}

	// very simple check sum function with a good chance to match
	// strings with different case equal
	static if (USE_HASHSUM) private static uint computeCheckSumI(string s)
	@trusted {
		uint csum = 0;
		immutable(char)* pc = s.ptr, pe = s.ptr + s.length;
		for (; pc != pe; pc++) {
			static if (case_sensitive) csum ^= *pc;
			else csum ^= *pc & 0x1101_1111;
			csum = (csum << 1) | (csum >> 31);
		}
		return csum;
	}
}

static assert(DictionaryList!(string, true, 2).safeValueCopy);

@safe unittest {
	DictionaryList!(int, true) a;
	a.addField("a", 1);
	a.addField("a", 2);
	assert(a["a"] == 1);
	assert(a.getAll("a") == [1, 2]);
	a["a"] = 3;
	assert(a["a"] == 3);
	assert(a.getAll("a") == [3, 2]);
	a.removeAll("a");
	assert(a.getAll("a").length == 0);
	assert(a.get("a", 4) == 4);
	a.addField("b", 2);
	a.addField("b", 1);
	a.remove("b");
	assert(a.getAll("b") == [1]);

	DictionaryList!(int, false) b;
	b.addField("a", 1);
	b.addField("A", 2);
	assert(b["A"] == 1);
	assert(b.getAll("a") == [1, 2]);
}