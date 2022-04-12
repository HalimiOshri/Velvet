#include "VtClothSolverGPU.cuh"
#include "Common.hpp"
#include "Common.cuh"
#include "Timer.hpp"

using namespace std;

// TODO(low): use cuda math structs instead of glm

namespace Velvet
{
	__device__ __constant__ VtSimParams d_params;
	VtSimParams h_params;

	void SetSimulationParams(VtSimParams* hostParams)
	{
		ScopedTimerGPU timer("Solver_SetParams");
		checkCudaErrors(cudaMemcpyToSymbolAsync(d_params, hostParams, sizeof(VtSimParams)));
		h_params = *hostParams;
	}

	struct InitializePositionsFunctor
	{
		const glm::mat4 matrix;
		InitializePositionsFunctor(glm::mat4 _matrix) : matrix(_matrix) {}

		__host__ __device__
			glm::vec3 operator()(const glm::vec3 position) const {
			return glm::vec3(matrix * glm::vec4(position, 1));
		}
	};

	void InitializePositions(glm::vec3* positions, int count, glm::mat4 modelMatrix)
	{
		ScopedTimerGPU timer("Solver_Initialize");
		thrust::device_ptr<glm::vec3> d_positions(positions);
		thrust::transform(d_positions, d_positions + count, d_positions, InitializePositionsFunctor(modelMatrix));
	}

	__global__ void EstimatePositions_Impl(CONST(glm::vec3*) positions, glm::vec3* predicted, glm::vec3* velocities, float deltaTime)
	{
		GET_CUDA_ID(id, d_params.numParticles);

		glm::vec3 gravity = glm::vec3(0, -10, 0);
		velocities[id] += d_params.gravity * deltaTime;
		predicted[id] = positions[id] + velocities[id] * deltaTime;
	}

	void EstimatePositions(CONST(glm::vec3*) positions, glm::vec3* predicted, glm::vec3* velocities, float deltaTime)
	{
		ScopedTimerGPU timer("Solver_Predict");
		CUDA_CALL(EstimatePositions_Impl, h_params.numParticles)(positions, predicted, velocities, deltaTime);
	}

	__device__ void AtomicAdd(glm::vec3* address, int index, glm::vec3 val, int reorder)
	{
		int r1 = reorder % 3;
		int r2 = (reorder+1) % 3;
		int r3 = (reorder+2) % 3;
		atomicAdd(&(address[index].x)+r1, val[r1]);
		atomicAdd(&(address[index].x)+r2, val[r2]);
		atomicAdd(&(address[index].x)+r3, val[r3]);
	}

	__global__ void SolveStretch_Impl(uint numConstraints, CONST(int*) stretchIndices, CONST(float*) stretchLengths, 
		CONST(float*) inverseMass, CONST(glm::vec3*) predicted, glm::vec3* positionDeltas, int* positionDeltaCount)
	{
		GET_CUDA_ID(id, numConstraints);

		int idx1 = stretchIndices[2 * id];
		int idx2 = stretchIndices[2 * id + 1];
		float expectedDistance = stretchLengths[id];

		glm::vec3 diff = predicted[idx1] - predicted[idx2];
		float distance = glm::length(diff);
		float w1 = inverseMass[idx1];
		float w2 = inverseMass[idx2];

		if (distance > expectedDistance && w1 + w2 > 0)
		{
			glm::vec3 gradient = diff / (distance + EPSILON);
			// compliance is zero, therefore XPBD=PBD
			float denom = w1 + w2;
			float lambda = (distance - expectedDistance) / denom;
			glm::vec3 common = lambda * gradient;
			glm::vec3 correction1 = -w1 * common;
			glm::vec3 correction2 = w2 * common;
			int reorder = idx1 + idx2;
			AtomicAdd(positionDeltas, idx1, correction1, reorder);
			AtomicAdd(positionDeltas, idx2, correction2, reorder);
			atomicAdd(&positionDeltaCount[idx1], 1);
			atomicAdd(&positionDeltaCount[idx2], 1);
			//printf("correction[%d] = (%.2f,%.2f,%.2f)\n", idx1, correction1.x, correction1.y, correction1.z);
			//printf("correction[%d] = (%.2f,%.2f,%.2f)\n", idx2, correction2.x, correction2.y, correction2.z);
		}
	}

	__global__ void ApplyPositionDeltas_Impl(glm::vec3* predicted, glm::vec3* positionDeltas, int* positionDeltaCount)
	{
		GET_CUDA_ID(id, d_params.numParticles);

		float count = (float)positionDeltaCount[id];
		if (count > 0)
		{
			predicted[id] += positionDeltas[id] / count;
			positionDeltas[id] = glm::vec3(0);
			positionDeltaCount[id] = 0;
		}
	}

	void SolveStretch(uint numConstraints, CONST(int*) stretchIndices, CONST(float*) stretchLengths,
		CONST(float*) inverseMass, glm::vec3* predicted, glm::vec3* positionDeltas, int* positionDeltaCount)
	{
		ScopedTimerGPU timer("Solver_SolveStretch");
		CUDA_CALL(SolveStretch_Impl, numConstraints)(numConstraints, stretchIndices, stretchLengths, inverseMass, predicted, positionDeltas, positionDeltaCount);
		CUDA_CALL(ApplyPositionDeltas_Impl, h_params.numParticles)(predicted, positionDeltas, positionDeltaCount);
	}

	__global__ void SolveAttachment_Impl(int numConstraints, CONST(int*) attachIndices, CONST(glm::vec3*) attachPositions, glm::vec3* predicted)
	{
		GET_CUDA_ID(id, numConstraints);

		predicted[attachIndices[id]] = attachPositions[id];
	}

	void SolveAttachment(int numConstraints, CONST(int*) attachIndices, CONST(glm::vec3*) attachPositions, glm::vec3* predicted)
	{
		ScopedTimerGPU timer("Solver_SolveAttach");
		CUDA_CALL(SolveAttachment_Impl, numConstraints)(numConstraints, attachIndices, attachPositions, predicted);
	}

	__device__ glm::vec3 ComputeFriction(glm::vec3 correction, glm::vec3 relVel)
	{
		glm::vec3 friction = glm::vec3(0);
		float correctionLength = glm::length(correction);
		if (d_params.friction > 0 && correctionLength > 0)
		{
			glm::vec3 norm = correction / correctionLength;

			glm::vec3 tanVel = relVel - norm * glm::dot(relVel, norm);
			float tanLength = glm::length(tanVel);
			float maxTanLength = correctionLength * d_params.friction;

			friction = -tanVel * min(maxTanLength / tanLength, 1.0f);
		}
		return friction;
	}

	__global__ void SolveSDFCollision_Impl(const uint numColliders, CONST(SDFCollider*) colliders, CONST(glm::vec3*) positions, glm::vec3* predicted)
	{
		GET_CUDA_ID(id, d_params.numParticles);

		glm::vec3 force = glm::vec3(0);
		for (int i = 0; i < numColliders; i++)
		{
			auto collider = colliders[i];
			auto pos = predicted[id];
			glm::vec3 correction = collider.ComputeSDF(pos, d_params.collisionMargin);
			force += correction;

			glm::vec3 relVel = predicted[id] - positions[id];
			auto friction = ComputeFriction(correction, relVel);
			force += friction;
		}
		predicted[id] += force;
	}

	void SolveSDFCollision(const uint numColliders, CONST(SDFCollider*) colliders, CONST(glm::vec3*) positions, glm::vec3* predicted)
	{
		ScopedTimerGPU timer("Solver_CollideSDFs");
		if (numColliders == 0) return;
		
		CUDA_CALL(SolveSDFCollision_Impl, h_params.numParticles)(numColliders, colliders, positions, predicted);
	}

	__global__ void SolveParticleCollision_Impl(
		CONST(float*) inverseMass,
		CONST(uint*) neighbors,
		CONST(glm::vec3*) positions,
		CONST(glm::vec3*) predicted,
		glm::vec3* positionDeltas,
		int* positionDeltaCount)
	{
		GET_CUDA_ID(id, d_params.numParticles);

		glm::vec3 positionDelta = glm::vec3(0);
		int deltaCount = 0;
		glm::vec3 pred_i = predicted[id];
		glm::vec3 vel_i = (pred_i - positions[id]);
		float w_i = inverseMass[id];

		for (int neighbor = id * d_params.maxNumNeighbors; neighbor < (id + 1) * d_params.maxNumNeighbors; neighbor++)
		{
			uint j = neighbors[neighbor];
			if (j > d_params.numParticles) break;

			float expectedDistance = d_params.particleDiameter;

			glm::vec3 pred_j = predicted[j];
			glm::vec3 diff = pred_i - pred_j;
			float distance = glm::length(diff);
			float w_j = inverseMass[j];

			if (distance < expectedDistance && w_i + w_j > 0)
			{
				glm::vec3 gradient = diff / (distance + EPSILON);
				float denom = w_i + w_j;
				float lambda = (distance - expectedDistance) / denom;
				glm::vec3 common = lambda * gradient;

				positionDelta -= w_i * common;
				deltaCount += 1;

				glm::vec3 relativeVelocity = vel_i - (pred_j - positions[j]);
				glm::vec3 friction = ComputeFriction(common, relativeVelocity);
				positionDelta += w_i * friction;
			}
		}

		positionDeltas[id] = positionDelta;
		positionDeltaCount[id] = deltaCount;
	}

	void SolveParticleCollision(
		CONST(float*) inverseMass,
		CONST(uint*) neighbors,
		CONST(glm::vec3*) positions,
		glm::vec3* predicted,
		glm::vec3* positionDeltas,
		int* positionDeltaCount)
	{
		ScopedTimerGPU timer("Solver_CollideParticles");
		CUDA_CALL(SolveParticleCollision_Impl, h_params.numParticles)(inverseMass, neighbors, positions, predicted, positionDeltas, positionDeltaCount);
		CUDA_CALL(ApplyPositionDeltas_Impl, h_params.numParticles)(predicted, positionDeltas, positionDeltaCount);
	}

	__global__ void UpdatePositionsAndVelocities_Impl(CONST(glm::vec3*) predicted, glm::vec3* velocities, glm::vec3* positions, float deltaTime)
	{
		GET_CUDA_ID(id, d_params.numParticles);

		velocities[id] = (predicted[id] - positions[id]) / deltaTime * (1 - d_params.damping * deltaTime);
		positions[id] = predicted[id];
	}

	void UpdatePositionsAndVelocities(CONST(glm::vec3*) predicted, glm::vec3* velocities, glm::vec3* positions, float deltaTime)
	{
		ScopedTimerGPU timer("Solver_Finalize");
		CUDA_CALL(UpdatePositionsAndVelocities_Impl, h_params.numParticles)(predicted, velocities, positions, deltaTime);
	}

	__global__ void ComputeTriangleNormals(uint numTriangles, CONST(glm::vec3*) positions, CONST(uint*) indices, glm::vec3* normals)
	{
		GET_CUDA_ID(id, numTriangles);
		uint idx1 = indices[id * 3];
		uint idx2 = indices[id * 3+1];
		uint idx3 = indices[id * 3+2];

		auto p1 = positions[idx1];
		auto p2 = positions[idx2];
		auto p3 = positions[idx3];

		auto normal = glm::cross(p2 - p1, p3 - p1);
		int reorder = idx1 + idx2 + idx3;
		AtomicAdd(normals, idx1, normal, reorder);
		AtomicAdd(normals, idx2, normal, reorder);
		AtomicAdd(normals, idx3, normal, reorder);
	}

	__global__ void ComputeVertexNormals(glm::vec3* normals)
	{
		GET_CUDA_ID(id, d_params.numParticles);

		//normals[id] = glm::vec3(0,1,0);
		normals[id] = glm::normalize(normals[id]);
	}

	void ComputeNormal(uint numTriangles, CONST(glm::vec3*) positions, CONST(uint*) indices, glm::vec3* normals)
	{
		ScopedTimerGPU timer("Solver_UpdateNormals");
		if (h_params.numParticles)
		{
			cudaMemsetAsync(normals, 0, h_params.numParticles * sizeof(glm::vec3));
			CUDA_CALL(ComputeTriangleNormals, numTriangles)(numTriangles, positions, indices, normals);
			CUDA_CALL(ComputeVertexNormals, h_params.numParticles)(normals);
		}
	}

}