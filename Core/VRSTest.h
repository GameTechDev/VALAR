#pragma once
#include <Math/Vector.h>

class CameraController;
class ColorBuffer;

enum UnitTestState
{
    TestStateNone,
    Setup,
    MoveCamera,
    RunExperiment,
    Wait,
    TakeScreenshot,
    AccumulateFrametime,
    Teardown,
};

enum UnitTestMode
{
    TestModeNone,
    LionHead,
    FirstFloor,
    Tapestry
};

class Location
{
private:
    const float heading;
    const float pitch;
    const Math::Vector3 position;

public:
    Location(float heading, float pitch, Math::Vector3 position) :
        heading(heading), pitch(pitch), position(position) {}
    Location() :
        heading(0.0f), pitch(0.0f), position(Math::Vector3(0.0f, 0.0f, 0.0f)) {}
    float GetHeading() const { return heading; }
    float GetPitch() const { return pitch; }
    Math::Vector3 GetPosition() const { return position; }
};

class Experiment
{
public:
    Experiment(std::string& experimentName, bool captureVRSbuffer, bool captureStats, bool isControl);

    void (*ExperimentFunction)();

    std::string& GetName();
    bool CaptureVRSBuffer();
    bool CaptureStats();
    bool IsControl();
private:
    bool m_isControl;
    bool m_captureVRSBuffer;
    bool m_captureStats;
    std::string m_experimentName;
};

class UnitTest
{
public:
    UnitTest(std::string& testName, UnitTestMode testMode);

    void AddExperiment(Experiment* exp);

    void Setup();

    std::string& GetName();
public:
    std::string m_testName;
    std::list<Experiment*> m_experiments;
    UnitTestMode m_testMode;
};

namespace VRSTest
{
    void Update(CameraController* camera, float deltaT);
    bool Render(CommandContext& context, ColorBuffer& source, ColorBuffer& vrsBuffer);
    void MoveCamera(CameraController* camera, UnitTestMode testMode);
    UnitTestMode CheckIfChangeLocationKeyPressed();
    void ResetExperimentData();
    void WriteExperimentData(
        std::string& AE, std::string& DSSIM, std::string& FUZZ, 
        std::string& MAE, std::string& MEPP, std::string& MSE, 
        std::string& NCC, std::string& PAE, std::string& PHASH, 
        std::string& RMSE, std::string& SSIM, std::string& PSNR, 
        std::string& FLIP);

}

