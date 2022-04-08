#include "GUI.hpp"

#include "Scene.hpp"
#include "VtEngine.hpp"

using namespace Velvet;

inline GUI* g_Gui;

#define SHORTCUT_BOOL(key, variable) if (Global::input->GetKeyDown(key)) variable = !variable

void GUI::RegisterDebug(function<void()> callback)
{
	g_Gui->m_showDebugInfo.push_back(callback);
}

void GUI::RegisterDebugOnce(function<void()> callback)
{
	g_Gui->m_showDebugInfoOnce.push_back(callback);
}

void GUI::RegisterDebugOnce(const string& debugMessage)
{
	//vprintf(debugMessage, args);
	g_Gui->m_showDebugInfoOnce.push_back([debugMessage]() {
		ImGui::Text(debugMessage.c_str());
		});
}

GUI::GUI(GLFWwindow* window)
{
	g_Gui = this;
	m_window = window;

	// Setup Dear ImGui context
	IMGUI_CHECKVERSION();
	ImGui::CreateContext();
	ImGuiIO& io = ImGui::GetIO(); (void)io;
	io.IniFilename = NULL;
	io.Fonts->AddFontFromFileTTF("Assets/DroidSans.ttf", 18);
	//io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;     // Enable Keyboard Controls
	//io.ConfigFlags |= ImGuiConfigFlags_NavEnableGamepad;      // Enable Gamepad Controls

	// Setup Dear ImGui style
	CustomizeStyle();

	// Setup Platform/Renderer backends
	const char* glsl_version = "#version 330";
	ImGui_ImplGlfw_InitForOpenGL(m_window, true);
	ImGui_ImplOpenGL3_Init(glsl_version);

	m_deviceName = string((char*)glGetString(GL_RENDERER));
	m_deviceName = m_deviceName.substr(0, m_deviceName.find("/"));
}

void GUI::OnUpdate()
{
	//static bool show_demo_window = true;
	//ImGui::ShowDemoWindow(&show_demo_window);
	ImGui_ImplOpenGL3_NewFrame();
	ImGui_ImplGlfw_NewFrame();
	ImGui::NewFrame();

	glfwGetWindowSize(m_window, &m_canvasWidth, &m_canvasHeight);

	ShowSceneWindow();
	ShowOptionWindow();
	ShowStatWindow();
}

void GUI::Render()
{
	ImGui::Render();
	ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
}

void GUI::ClearCallback()
{
	m_showDebugInfo.clear();
	m_showDebugInfoOnce.clear();
}

void GUI::ShutDown()
{
	ImGui_ImplOpenGL3_Shutdown();
	ImGui_ImplGlfw_Shutdown();
	ImGui::DestroyContext();
}

void GUI::CustomizeStyle()
{
	ImGui::StyleColorsDark();

	auto style = &ImGui::GetStyle();
	style->SelectableTextAlign = ImVec2(0, 0.5);
	style->WindowPadding = ImVec2(10, 12);
	style->WindowRounding = 6;
	style->GrabRounding = 8;
	style->FrameRounding = 6;
	style->WindowTitleAlign = ImVec2(0.5, 0.5);

	style->Colors[ImGuiCol_WindowBg] = ImVec4(0.06f, 0.06f, 0.06f, 0.6f);
	style->Colors[ImGuiCol_TitleBg] = style->Colors[ImGuiCol_WindowBg];
	style->Colors[ImGuiCol_TitleBgActive] = style->Colors[ImGuiCol_TitleBg];
	style->Colors[ImGuiCol_SliderGrab] = ImVec4(0.325f, 0.325f, 0.325f, 1.0f);
	style->Colors[ImGuiCol_FrameBg] = ImVec4(0.114f, 0.114f, 0.114f, 1.0f);
	style->Colors[ImGuiCol_FrameBgHovered] = ImVec4(0.2f, 0.2f, 0.2f, 1.0f);
	style->Colors[ImGuiCol_Button] = ImVec4(0.46f, 0.46f, 0.46f, 0.46f);
	style->Colors[ImGuiCol_CheckMark] = ImVec4(0.851f, 0.851f, 0.851f, 1.0f);
	//ImGui::StyleColorsClassic();
}

void GUI::ShowSceneWindow()
{
	ImGui::SetNextWindowSize(ImVec2(k_windowWidth, (m_canvasHeight - 60.0f) * 0.4f));
	ImGui::SetNextWindowPos(ImVec2(20, 20));
	ImGui::Begin("Scene", NULL, k_windowFlags);

	const auto& scenes = Global::engine->scenes;

	for (unsigned int i = 0; i < scenes.size(); i++)
	{
		auto scene = scenes[i];
		auto label = scene->name;
		if (ImGui::Selectable(label.c_str(), Global::engine->sceneIndex == i, 0, ImVec2(0, 28)))
		{
			Global::engine->SwitchScene(i);
		}
	}

	ImGui::End();
}

void GUI::ShowOptionWindow()
{
	ImGui::SetNextWindowSize(ImVec2(k_windowWidth, (m_canvasHeight - 60.0f) * 0.6f));
	ImGui::SetNextWindowPos(ImVec2(20, 40 + (m_canvasHeight - 60.0f) * 0.4f));
	ImGui::Begin("Options", NULL, k_windowFlags);

	ImGui::PushItemWidth(-FLT_MIN);

	if (ImGui::Button("Reset (R)", ImVec2(-FLT_MIN, 0)))
	{
		Global::engine->Reset();
	}
	ImGui::Dummy(ImVec2(0.0f, 10.0f));

	if (ImGui::CollapsingHeader("Global", ImGuiTreeNodeFlags_DefaultOpen))
	{
		static bool radio = false;
		ImGui::Checkbox("Pause (P, O)", &Global::gameState.pause);
		Global::input->ToggleOnKeyDown(GLFW_KEY_P, Global::gameState.pause);
		ImGui::Checkbox("Draw Particles (K)", &Global::gameState.drawParticles);
		Global::input->ToggleOnKeyDown(GLFW_KEY_K, Global::gameState.drawParticles);
		ImGui::Checkbox("Draw Wireframe (L)", &Global::gameState.renderWireframe);
		Global::input->ToggleOnKeyDown(GLFW_KEY_L, Global::gameState.renderWireframe);
		ImGui::Dummy(ImVec2(0.0f, 10.0f));
	}

	if (ImGui::CollapsingHeader("Simulation", ImGuiTreeNodeFlags_DefaultOpen))
	{
		//IMGUI_LEFT_LABEL(ImGui::SliderFloat3, "LightPos", (float*)&(Global::lights[0]->transform()->position), -5, 5, "%.2f");
		//IMGUI_LEFT_LABEL(ImGui::SliderFloat3, "LightRot", (float*)&(Global::lights[0]->transform()->rotation), -79, 79, "%.2f");

		Global::simParams.OnGUI();
	}

	ImGui::End();
}

void GUI::ShowStatWindow()
{
	ImGui::SetNextWindowSize(ImVec2(k_windowWidth * 1.1f, 0));
	ImGui::SetNextWindowPos(ImVec2(m_canvasWidth - k_windowWidth * 1.1f - 20, 20.0f));
	ImGui::Begin("Statistics", NULL, k_windowFlags);

	static PerformanceStat stat;
	stat.Update();

	ImGui::Text("Device:  %s", m_deviceName.c_str());
	ImGui::Text("Frame:  %d; Physics Frame:%d", stat.frameCount, stat.physicsFrameCount);
	ImGui::Text("Avg FrameRate:  %d FPS", stat.frameRate);
	ImGui::Text("CPU time:  %.2f ms", stat.cpuTime);
	ImGui::Text("GPU time:  %.2f ms", stat.gpuTime);

	ImGui::Dummy(ImVec2(0, 5));
	auto overlay = fmt::format("{:.2f} ms ({:.2f} FPS)", stat.deltaTime, 1000.0 / stat.deltaTime);
	ImGui::PlotLines("##", stat.graphValues, IM_ARRAYSIZE(stat.graphValues), stat.graphIndex, overlay.c_str(),
		0, stat.graphAverage * 2.0f, ImVec2(k_windowWidth + 5.0f, 80.0f));
	ImGui::Dummy(ImVec2(0, 5));

	ImGui::PushItemWidth(-FLT_MIN);

	if (m_showDebugInfo.size() + m_showDebugInfoOnce.size() > 0)
	{
		if (ImGui::CollapsingHeader("Debug", ImGuiTreeNodeFlags_DefaultOpen))
		{
			for (auto callback : m_showDebugInfo)
			{
				callback();
			}
			for (auto callback : m_showDebugInfoOnce)
			{
				callback();
			}
			if (!Global::gameState.pause)
			{
				m_showDebugInfoOnce.clear();
			}
		}
	}

	ImGui::End();
}