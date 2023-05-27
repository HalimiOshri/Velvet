#pragma once

#include <iostream>
#include <string>

#include "Transform.hpp"

#define SET_COMPONENT_NAME name = __func__

namespace VRThreads
{
	using namespace std;

	class Actor;

	class Component
	{
	public:
		virtual void Start() {}

		virtual void Update() { }

		virtual void Progress(float time) {} // OH: to allow time dependent update

		virtual void FixedUpdate() {}

		virtual void OnDestroy() {}

		string name = "Component";

		Actor* actor = nullptr;

		shared_ptr<Transform> transform();

		bool enabled = true;
	};
}