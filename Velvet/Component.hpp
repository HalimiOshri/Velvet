#pragma once

#include <iostream>
#include <string>

#include "Transform.hpp"

namespace Velvet
{
	using namespace std;

	class Actor;

	class Component
	{
	public:
		virtual void Start() {}

		virtual void Update() { }

		virtual void OnDestroy() {}

		string name = "Component";

		Actor* actor;

		shared_ptr<Transform> transform();
	};
}