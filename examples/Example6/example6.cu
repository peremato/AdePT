// SPDX-FileCopyrightText: 2020 CERN
// SPDX-License-Identifier: Apache-2.0

#include <AdePT/Atomic.h>
#include <AdePT/BlockData.h>
#include <AdePT/LoopNavigator.h>
#include <AdePT/MParray.h>

#include <VecGeom/base/Config.h>
#include <VecGeom/base/Stopwatch.h>
#ifdef VECGEOM_ENABLE_CUDA
#include <VecGeom/backend/cuda/Interface.h>
#endif

#include <G4NistManager.hh>
#include <G4Material.hh>

#include <G4Box.hh>
#include <G4LogicalVolume.hh>
#include <G4PVPlacement.hh>

#include <G4ParticleTable.hh>
#include <G4Electron.hh>
#include <G4Positron.hh>
#include <G4Gamma.hh>
#include <G4Proton.hh>

#include <G4ProductionCuts.hh>
#include <G4Region.hh>
#include <G4ProductionCutsTable.hh>

#include <G4UnitsTable.hh>
#include <G4SystemOfUnits.hh>

#include <G4HepEmData.hh>
#include <G4HepEmElectronInit.hh>
#include <G4HepEmMatCutData.hh>
#include <G4HepEmMaterialInit.hh>
#include <G4HepEmParameters.hh>
#include <G4HepEmParametersInit.hh>

#include <G4HepEmElectronManager.hh>
#include <G4HepEmElectronTrack.hh>
#include <G4HepEmElectronInteractionBrem.hh>
#include <G4HepEmElectronInteractionIoni.hh>
#include <G4HepEmPositronInteractionAnnihilation.hh>
// Pull in implementation.
#include <G4HepEmRunUtils.icc>
#include <G4HepEmElectronManager.icc>
#include <G4HepEmElectronInteractionBrem.icc>
#include <G4HepEmElectronInteractionIoni.icc>
#include <G4HepEmPositronInteractionAnnihilation.icc>

#include <CopCore/Global.h>
#include <CopCore/PhysicalConstants.h>
#include <CopCore/Ranluxpp.h>

#include <track.h>
#include <ConstBzFieldStepper.h>
#include <fieldPropagatorConstBz.h>

#include "example6.h"

#include <iostream>
#include <iomanip>
#include <stdio.h>

// A data structure for some simple scoring.
struct Scoring {
  adept::Atomic_t<int> hits;
  adept::Atomic_t<int> secondaries;
  adept::Atomic_t<float> totalEnergyDeposit;

  __host__ __device__ Scoring() {}

  __host__ __device__ static Scoring *MakeInstanceAt(void *addr)
  {
    Scoring *obj = new (addr) Scoring();
    return obj;
  }
};

constexpr float BzFieldValue = 0.1 * copcore::units::tesla;

static void InitGeant4()
{
  // --- Create materials.
  G4Material *galactic = G4NistManager::Instance()->FindOrBuildMaterial("G4_Galactic");
  G4Material *silicon  = G4NistManager::Instance()->FindOrBuildMaterial("G4_Si");
  //
  // --- Define a world.
  G4double worldDim         = 1 * m;
  G4Box *worldBox           = new G4Box("world", worldDim, worldDim, worldDim);
  G4LogicalVolume *worldLog = new G4LogicalVolume(worldBox, galactic, "world");
  G4PVPlacement *world      = new G4PVPlacement(nullptr, {}, worldLog, "world", nullptr, false, 0);
  // --- Define a box.
  G4double boxDim             = 0.5 * m;
  G4double boxPos             = 0.5 * boxDim;
  G4Box *siliconBox           = new G4Box("silicon", boxDim, boxDim, boxDim);
  G4LogicalVolume *siliconLog = new G4LogicalVolume(siliconBox, silicon, "silicon");
  new G4PVPlacement(nullptr, {boxPos, boxPos, boxPos}, siliconLog, "silicon", worldLog, false, 0);
  //
  // --- Create particles that have secondary production threshold.
  G4Gamma::Gamma();
  G4Electron::Electron();
  G4Positron::Positron();
  G4Proton::Proton();
  G4ParticleTable *partTable = G4ParticleTable::GetParticleTable();
  partTable->SetReadiness();
  //
  // --- Create production - cuts object and set the secondary production threshold.
  G4ProductionCuts *productionCuts = new G4ProductionCuts();
  constexpr G4double ProductionCut = 1 * mm;
  productionCuts->SetProductionCut(ProductionCut);
  //
  // --- Register a region for the world.
  G4Region *reg = new G4Region("default");
  reg->AddRootLogicalVolume(worldLog);
  reg->UsedInMassGeometry(true);
  reg->SetProductionCuts(productionCuts);
  //
  // --- Update the couple tables.
  G4ProductionCutsTable *theCoupleTable = G4ProductionCutsTable::GetProductionCutsTable();
  theCoupleTable->UpdateCoupleTable(world);
}

__constant__ __device__ struct G4HepEmParameters g4HepEmPars;
__constant__ __device__ struct G4HepEmData g4HepEmData;

struct G4HepEmState {
  G4HepEmData data;
  G4HepEmParameters parameters;
};

static G4HepEmState *InitG4HepEm()
{
  G4HepEmState *state = new G4HepEmState;
  InitG4HepEmData(&state->data);
  InitHepEmParameters(&state->parameters);

  InitMaterialAndCoupleData(&state->data, &state->parameters);

  InitElectronData(&state->data, &state->parameters, true);
  InitElectronData(&state->data, &state->parameters, false);

  G4HepEmMatCutData *cutData = state->data.fTheMatCutData;
  G4cout << "fNumG4MatCuts = " << cutData->fNumG4MatCuts << ", fNumMatCutData = " << cutData->fNumMatCutData << G4endl;

  // Copy to GPU.
  CopyG4HepEmDataToGPU(&state->data);
  COPCORE_CUDA_CHECK(cudaMemcpyToSymbol(g4HepEmPars, &state->parameters, sizeof(G4HepEmParameters)));

  // Create G4HepEmData with the device pointers.
  G4HepEmData dataOnDevice;
  dataOnDevice.fTheMatCutData   = state->data.fTheMatCutData_gpu;
  dataOnDevice.fTheMaterialData = state->data.fTheMaterialData_gpu;
  dataOnDevice.fTheElementData  = state->data.fTheElementData_gpu;
  dataOnDevice.fTheElectronData = state->data.fTheElectronData_gpu;
  dataOnDevice.fThePositronData = state->data.fThePositronData_gpu;
  dataOnDevice.fTheSBTableData  = state->data.fTheSBTableData_gpu;
  // The other pointers should never be used.
  dataOnDevice.fTheMatCutData_gpu   = nullptr;
  dataOnDevice.fTheMaterialData_gpu = nullptr;
  dataOnDevice.fTheElementData_gpu  = nullptr;
  dataOnDevice.fTheElectronData_gpu = nullptr;
  dataOnDevice.fThePositronData_gpu = nullptr;
  dataOnDevice.fTheSBTableData_gpu  = nullptr;

  COPCORE_CUDA_CHECK(cudaMemcpyToSymbol(g4HepEmData, &dataOnDevice, sizeof(G4HepEmData)));

  return state;
}

static void FreeG4HepEm(G4HepEmState *state)
{
  FreeG4HepEmData(&state->data);
  delete state;
}

__device__ struct G4HepEmElectronManager electronManager;

// Compute the physics and geomtry step limit, transport the particle while
// applying the continuous effects and possibly select a discrete process that
// could generate secondaries.
__global__ void PerformStep(adept::BlockData<track> *allTracks, adept::MParray *discreteQueue, Scoring *scoring,
                            int maxIndex)
{
  fieldPropagatorConstBz fieldPropagatorBz(BzFieldValue);

  for (int i = blockIdx.x * blockDim.x + threadIdx.x; i < maxIndex; i += blockDim.x * gridDim.x) {
    track &currentTrack = (*allTracks)[i];

    // Skip particles that are already dead.
    if (currentTrack.status == dead) continue;

    // Experimental limit on number of steps - to avoid 'forever' particles
    // Configurable in real simulation -- 1000 ?
    constexpr uint16_t maxNumSteps = 250;
    ++currentTrack.num_step;
    if (currentTrack.num_step > maxNumSteps) {
      currentTrack.status = dead;
      allTracks->ReleaseElement(i);
      continue;
    }

    // Init a track with the needed data to call into G4HepEm.
    G4HepEmElectronTrack elTrack;
    G4HepEmTrack *theTrack = elTrack.GetTrack();
    // Transform the units ...
    theTrack->SetEKin(currentTrack.energy / copcore::units::GeV * GeV);
    // For now, just assume a single material.
    theTrack->SetMCIndex(1);
    // In this kernel, we only have electrons and positrons.
    const bool isElectron = currentTrack.pdg == track::pdgElectron;
    theTrack->SetCharge(isElectron ? -1.0 : 1.0);

    // Sample the `number-of-interaction-left` and put it into the track.
    for (int ip = 0; ip < 3; ++ip) {
      double numIALeft = currentTrack.numIALeft[ip];
      if (numIALeft <= 0) {
        numIALeft                  = -std::log(currentTrack.uniform());
        currentTrack.numIALeft[ip] = numIALeft;
      }
      theTrack->SetNumIALeft(numIALeft, ip);
    }

    // Call G4HepEm to compute the physics step limit.
    electronManager.HowFar(&g4HepEmData, &g4HepEmPars, &elTrack);

    // Get result into variables and transform the units.
    double geometricalStepLengthFromPhysics = theTrack->GetGStepLength() / mm * copcore::units::mm;
    // The phyiscal step length is the amount that the particle experiences
    // which might be longer than the geometrical step length due to MSC. As
    // long as we call PerformContinuous in the same kernel we don't need to
    // care, but we need to make this available when splitting the operations.
    // double physicalStepLength = elTrack.GetPStepLength();
    int winnerProcessIndex = theTrack->GetWinnerProcessIndex();
    // Leave the range and MFP inside the G4HepEmTrack. If we split kernels, we
    // also need to carry them over!

    // Check if there's a volume boundary in between.
    double geometryStepLength = fieldPropagatorBz.ComputeStepAndPropagatedState</*Relocate=*/false>(
        currentTrack, geometricalStepLengthFromPhysics);
    currentTrack.total_length += geometryStepLength;

    if (currentTrack.next_state.IsOnBoundary()) {
      theTrack->SetGStepLength(geometryStepLength / copcore::units::cm * cm);
      theTrack->SetOnBoundary(true);
    }

    // Apply continuous effects.
    bool stopped = electronManager.PerformContinuous(&g4HepEmData, &g4HepEmPars, &elTrack);
    // Collect the changes.
    double energyDeposit    = theTrack->GetEnergyDeposit();
    double newKineticEnergy = theTrack->GetEKin();
    // Transform the units ...
    currentTrack.energy = newKineticEnergy / MeV * copcore::units::MeV;
    scoring->totalEnergyDeposit.fetch_add(energyDeposit / MeV * copcore::units::MeV);

    // Save the `number-of-interaction-left` in our track.
    for (int ip = 0; ip < 3; ++ip) {
      double numIALeft           = theTrack->GetNumIALeft(ip);
      currentTrack.numIALeft[ip] = numIALeft;
    }

    if (stopped) {
      if (!isElectron) {
        // For a stopped positron, we should call annihilation but this produces
        // a gamma which we don't yet have processes for. Deposit the amount of
        // energy that the photon would have from the annihilation at rest with
        // an electron.
        scoring->totalEnergyDeposit.fetch_add(2 * copcore::units::kElectronMassC2);
      }
      allTracks->ReleaseElement(i);
      currentTrack.status = dead;
      continue;
    }

    if (currentTrack.next_state.IsOnBoundary()) {
      // For now, just count that we hit something.
      scoring->hits++;

      LoopNavigator::RelocateToNextVolume(currentTrack.pos, currentTrack.dir, currentTrack.next_state);

      // Move to the next boundary.
      currentTrack.SwapStates();
      continue;
    } else if (winnerProcessIndex < 0) {
      // No discrete process, move on.
      continue;
    }

    // Reset number of interaction left for the winner discrete process.
    // (Will be resampled in the next iteration.)
    currentTrack.numIALeft[winnerProcessIndex] = -1.0;

    // Check if a delta interaction happens instead of the real discrete process.
    if (electronManager.CheckDelta(&g4HepEmData, theTrack, currentTrack.uniform())) {
      // A delta interaction happened, move on.
      continue;
    }

    // Queue the particle (via its index) to perform the discrete interaction.
    currentTrack.current_process = winnerProcessIndex;
    discreteQueue->push_back(i);
  }
}

class RanluxppDoubleEngine : public G4HepEmRandomEngine {
  // Wrapper functions to call into CLHEP::HepRandomEngine.
  static __host__ __device__ double flatWrapper(void *object) { return ((RanluxppDouble *)object)->Rndm(); }
  static __host__ __device__ void flatArrayWrapper(void *object, const int size, double *vect)
  {
    for (int i = 0; i < size; i++) {
      vect[i] = ((RanluxppDouble *)object)->Rndm();
    }
  }

public:
  __host__ __device__ RanluxppDoubleEngine(RanluxppDouble *engine)
      : G4HepEmRandomEngine(/*object=*/engine, &flatWrapper, &flatArrayWrapper)
  {
  }
};

__host__ __device__ void InitSecondary(track &secondary, const track &parent)
{
  // For tracing / debugging.
  secondary.index        = 10 * parent.index + parent.number_of_secondaries;
  secondary.mother_index = parent.index;
  secondary.eventId      = parent.eventId;
  secondary.status       = alive;

  // The caller is responsible to set the energy.
  secondary.numIALeft[0] = -1.0;
  secondary.numIALeft[1] = -1.0;
  secondary.numIALeft[2] = -1.0;

  secondary.interaction_length = 0.0;
  secondary.total_length       = 0.0;

  secondary.number_of_secondaries = 0;
  secondary.energy_loss           = 0;

  secondary.num_step        = 0;
  secondary.current_process = -1;
  // The caller is responsible to set the particle type (via pdg).

  // A secondary inherits the position of its parent; the caller is responsible
  // to update the directions.
  secondary.pos           = parent.pos;
  secondary.current_state = parent.current_state;
  secondary.next_state    = parent.current_state;

  // Initialize a new PRNG state.
  secondary.rng_state = parent.rng_state;
  secondary.rng_state.Skip(1 << 15);
}

// Create a pair of e-/e+ from the intermediate gamma.
__host__ __device__ void PairProduce(adept::BlockData<track> *allTracks, track &currentTrack, double energy,
                                     const double *dir)
{
  auto electron = allTracks->NextElement();
  if (electron == nullptr) {
    COPCORE_EXCEPTION("No slot available for secondary electron track");
  }
  auto positron = allTracks->NextElement();
  if (positron == nullptr) {
    COPCORE_EXCEPTION("No slot available for secondary positron track");
  }

  // TODO: Distribute energy and momentum.
  double remainingEnergy = energy - 2 * copcore::units::kElectronMassC2;

  InitSecondary(*electron, /*parent=*/currentTrack);
  electron->pdg    = track::pdgElectron;
  electron->energy = remainingEnergy / 2;
  electron->dir.Set(dir[0], dir[1], dir[2]);

  InitSecondary(*positron, /*parent=*/currentTrack);
  positron->pdg    = track::pdgPositron;
  positron->energy = remainingEnergy / 2;
  positron->dir.Set(dir[0], dir[1], dir[2]);
}

// Perform the discrete interactions for e-/e+; for photons, either pair-produce
// or deposit the energy.
__global__ void PerformDiscreteInteractions(adept::BlockData<track> *allTracks, adept::MParray *discreteQueue,
                                            Scoring *scoring)
{
  int queueSize = discreteQueue->size();
  for (int i = blockIdx.x * blockDim.x + threadIdx.x; i < queueSize; i += blockDim.x * gridDim.x) {
    int particleIndex   = (*discreteQueue)[i];
    track &currentTrack = (*allTracks)[particleIndex];
    RanluxppDoubleEngine rnge(&currentTrack.rng_state);

    // For now, just assume a single material.
    int theMCIndex             = 1;
    const double energy        = currentTrack.energy;
    const double energyG4HepEm = energy / copcore::units::GeV * GeV;
    const double theElCut      = g4HepEmData.fTheMatCutData->fMatCutData[theMCIndex].fSecElProdCutE;
    // In this kernel, we only have electrons and positrons.
    const bool isElectron = currentTrack.pdg == track::pdgElectron;

    switch (currentTrack.current_process) {
    case 0: {
      // Invoke ioninization (for e-/e+):
      double deltaEkin = (isElectron) ? SampleETransferMoller(theElCut, energyG4HepEm, &rnge)
                                      : SampleETransferBhabha(theElCut, energyG4HepEm, &rnge);

      double dirPrimary[] = {currentTrack.dir.x(), currentTrack.dir.y(), currentTrack.dir.z()};
      double dirSecondary[3];
      SampleDirectionsIoni(energyG4HepEm, deltaEkin, dirSecondary, dirPrimary, &rnge);
      deltaEkin = deltaEkin / MeV * copcore::units::MeV;

      auto secondary = allTracks->NextElement();
      if (secondary == nullptr) {
        COPCORE_EXCEPTION("No slot available for secondary track");
      }
      currentTrack.number_of_secondaries++;
      scoring->secondaries++;

      InitSecondary(*secondary, /*parent=*/currentTrack);
      secondary->pdg    = track::pdgElectron;
      secondary->energy = deltaEkin;
      secondary->dir.Set(dirSecondary[0], dirSecondary[1], dirSecondary[2]);

      currentTrack.energy = energy - deltaEkin;
      currentTrack.dir.Set(dirPrimary[0], dirPrimary[1], dirPrimary[2]);
      break;
    }
    case 1: {
      // Invoke model for Bremsstrahlung: either SB- or Rel-Brem.
      double logEnergy = std::log(energyG4HepEm);
      double deltaEkin =
          energyG4HepEm < g4HepEmPars.fElectronBremModelLim
              ? SampleETransferBremSB(&g4HepEmData, energyG4HepEm, logEnergy, theMCIndex, &rnge, isElectron)
              : SampleETransferBremRB(&g4HepEmData, energyG4HepEm, logEnergy, theMCIndex, &rnge, isElectron);
      double transformedDeltaEkin = deltaEkin / MeV * copcore::units::MeV;

      // We would need to create a gamma, but only do so if it has enough energy
      // to immediately pair-produce. Otherwise just deposit the energy locally.
      if (transformedDeltaEkin > 2 * copcore::units::kElectronMassC2) {
        double dirPrimary[] = {currentTrack.dir.x(), currentTrack.dir.y(), currentTrack.dir.z()};
        double dirSecondary[3];
        SampleDirectionsBrem(energyG4HepEm, deltaEkin, dirSecondary, dirPrimary, &rnge);

        PairProduce(allTracks, currentTrack, transformedDeltaEkin, dirSecondary);
        currentTrack.number_of_secondaries += 2;
        scoring->secondaries += 2;
      } else {
        scoring->totalEnergyDeposit.fetch_add(transformedDeltaEkin);
      }

      currentTrack.energy = energy - transformedDeltaEkin;
      break;
    }
    case 2: {
      // Invoke annihilation (in-flight) for e+

      double dirPrimary[] = {currentTrack.dir.x(), currentTrack.dir.y(), currentTrack.dir.z()};
      double theGamma1Ekin, theGamma2Ekin;
      double theGamma1Dir[3], theGamma2Dir[3];
      SampleEnergyAndDirectionsForAnnihilationInFlight(energyG4HepEm, dirPrimary, &theGamma1Ekin, theGamma1Dir,
                                                       &theGamma2Ekin, theGamma2Dir, &rnge);
      theGamma1Ekin = theGamma1Ekin / MeV * copcore::units::MeV;
      theGamma2Ekin = theGamma2Ekin / MeV * copcore::units::MeV;

      // For each of the two gammas, pair-produce if they have enough energy
      // or deposit the energy locally.
      if (theGamma1Ekin > 2 * copcore::units::kElectronMassC2) {
        PairProduce(allTracks, currentTrack, theGamma1Ekin, theGamma1Dir);
        currentTrack.number_of_secondaries += 2;
        scoring->secondaries += 2;
      } else {
        scoring->totalEnergyDeposit.fetch_add(theGamma1Ekin);
      }
      if (theGamma2Ekin > 2 * copcore::units::kElectronMassC2) {
        PairProduce(allTracks, currentTrack, theGamma2Ekin, theGamma2Dir);
        currentTrack.number_of_secondaries += 2;
        scoring->secondaries += 2;
      } else {
        scoring->totalEnergyDeposit.fetch_add(theGamma2Ekin);
      }

      // Kill the current track.
      currentTrack.status = dead;
      allTracks->ReleaseElement(particleIndex);
      break;
    }
    }
  }
}

// kernel function to initialize a single track, most importantly the random state
__global__ void init_track(track *mytrack, const vecgeom::VPlacedVolume *world)
{
  /* we have to initialize the state */
  mytrack->rng_state.SetSeed(314159265);
  LoopNavigator::LocatePointIn(world, mytrack->pos, mytrack->current_state, true);
  mytrack->next_state = mytrack->current_state;
}

//
void example6(const vecgeom::cxx::VPlacedVolume *world)
{
  auto &cudaManager = vecgeom::cxx::CudaManager::Instance();
  cudaManager.LoadGeometry(world);
  cudaManager.Synchronize();

  const vecgeom::cuda::VPlacedVolume *gpu_world = cudaManager.world_gpu();

  InitGeant4();
  G4HepEmState *state = InitG4HepEm();

  // Capacity of the different containers aka the maximum number of particles
  // that can be in flight concurrently.
  constexpr int Capacity = 256 * 1024;

  std::cout << "INFO: capacity of containers (incl. BlockData<track>) set at " << Capacity << std::endl;

  // Allocate a block holding all tracks.
  size_t blockSize  = adept::BlockData<track>::SizeOfInstance(Capacity);
  void *blockBuffer = nullptr;
  COPCORE_CUDA_CHECK(cudaMallocManaged(&blockBuffer, blockSize));
  auto allTracks = adept::BlockData<track>::MakeInstanceAt(Capacity, blockBuffer);

  size_t queueSize = adept::MParray::SizeOfInstance(Capacity);

  // Allocate a queue to remember all particles that have a discrete
  // interaction. This potentially creates secondaries, so we must be
  // careful to not spawn particles in holes of the above block.
  void *discreteBuffer = nullptr;
  COPCORE_CUDA_CHECK(cudaMallocManaged(&discreteBuffer, queueSize));
  auto discreteQueue = adept::MParray::MakeInstanceAt(Capacity, discreteBuffer);

  // Allocate and initialize a primitive version of Scoring.
  char *scoringBuffer = nullptr;
  COPCORE_CUDA_CHECK(cudaMallocManaged(&scoringBuffer, sizeof(Scoring)));
  Scoring *scoring            = Scoring::MakeInstanceAt(scoringBuffer);
  scoring->hits               = 0;
  scoring->secondaries        = 0;
  scoring->totalEnergyDeposit = 0;

  // Initializing one primary electron.
  auto primaryElectron          = allTracks->NextElement();
  primaryElectron->index        = 1;
  primaryElectron->energy       = 100.0f * copcore::units::GeV;
  primaryElectron->numIALeft[0] = -1.0;
  primaryElectron->numIALeft[1] = -1.0;
  primaryElectron->numIALeft[2] = -1.0;

  primaryElectron->pos = {0, 0, 0};
  primaryElectron->dir = {1.0, 0, 0};
  // current_state and next_state are set on the GPU via init_track below.

  primaryElectron->mother_index = 1;
  primaryElectron->eventId      = 101;
  primaryElectron->status       = alive;

  primaryElectron->interaction_length = 0.0;
  primaryElectron->total_length       = 0.0;

  primaryElectron->number_of_secondaries = 0;
  primaryElectron->energy_loss           = 0.0;

  primaryElectron->num_step = 0;

  primaryElectron->current_process = -1;
  primaryElectron->pdg             = track::pdgElectron;

  init_track<<<1, 1>>>(primaryElectron, gpu_world);
  COPCORE_CUDA_CHECK(cudaDeviceSynchronize());

  std::cout << "INFO: running with field Bz = " << BzFieldValue / copcore::units::tesla << " T";
  std::cout << std::endl;

  constexpr int maxBlocks   = 1024;
  constexpr int allThreads  = 32;
  constexpr int usedThreads = 32;
  int allBlocks, usedBlocks;

  vecgeom::Stopwatch timer;
  timer.Start();

  int inFlight = allTracks->GetNused();
  int iterNo = 0;

  do {
    int maxIndex = inFlight + allTracks->GetNholes();

    allBlocks = (maxIndex + allThreads - 1) / allThreads;
    allBlocks = std::min(allBlocks, maxBlocks);

    usedBlocks = (inFlight + usedThreads - 1) / usedThreads;
    usedBlocks = std::min(usedBlocks, maxBlocks);

    // Call the kernel to compute the physics and geomtry step limit, transport
    // the particle while applying the continuous effects and possibly select a
    // discrete process that could generate secondaries.
    PerformStep<<<allBlocks, allThreads>>>(allTracks, discreteQueue, scoring, maxIndex);

    // Call the kernel to perform the discrete interactions.
    PerformDiscreteInteractions<<<usedBlocks, usedThreads>>>(allTracks, discreteQueue, scoring);

    COPCORE_CUDA_CHECK(cudaDeviceSynchronize());

    // Clear the queue of particles that just had their discrete interaction.
    discreteQueue->clear();
    COPCORE_CUDA_CHECK(cudaDeviceSynchronize());

    inFlight = allTracks->GetNused();

    std::cout << std::fixed << std::setprecision(4) << std::setfill(' ');
    std::cout << "iter " << std::setw(4) << iterNo << " -- tracks in flight: " << std::setw(5) << inFlight
              << " energy deposition: " << std::setw(10) << scoring->totalEnergyDeposit.load()
              << " number of secondaries: " << std::setw(5) << scoring->secondaries.load()
              << " number of hits: " << std::setw(4) << scoring->hits.load();
    std::cout << std::endl;

    iterNo++;
  } while (inFlight > 0 && iterNo < 1000);

  auto time_cpu = timer.Stop();
  std::cout << "Run time: " << time_cpu << "\n";

  FreeG4HepEm(state);
}