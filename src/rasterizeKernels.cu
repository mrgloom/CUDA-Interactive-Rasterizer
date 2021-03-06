// CIS565 CUDA Rasterizer: A simple rasterization pipeline for Patrick Cozzi's CIS565: GPU Computing at the University of Pennsylvania
// Written by Yining Karl Li, Copyright (c) 2012 University of Pennsylvania

#include <stdio.h>
#include <cuda.h>
#include <cmath>
#include <thrust/random.h>
#include "rasterizeKernels.h"
#include "rasterizeTools.h"
#include <thrust/device_vector.h>


#if CUDA_VERSION >= 5000
    #include <helper_math.h>
#else
    #include <cutil_math.h>
#endif

glm::vec3* framebuffer;
fragment* depthbuffer;
int* lockbuffer;
float* device_vbo;
float* device_vbo_proj;
float* device_cbo;
float* device_nbo;
int* device_ibo;
triangle* primitives;

void checkCUDAError(const char *msg) {
  cudaError_t err = cudaGetLastError();
  if( cudaSuccess != err) {
    fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString( err) ); 
    exit(EXIT_FAILURE); 
  }
} 

__host__ __device__ bool operator<(const fragment &lhs, const fragment &rhs) 
{
	return lhs.position.z < rhs.position.z;
}

__host__ __device__ bool operator>(const fragment &lhs, const fragment &rhs) 
{
	return lhs.position.z > rhs.position.z;
}

//Handy dandy little hashing function that provides seeds for random number generation
__host__ __device__ unsigned int hash(unsigned int a){
    a = (a+0x7ed55d16) + (a<<12);
    a = (a^0xc761c23c) ^ (a>>19);
    a = (a+0x165667b1) + (a<<5);
    a = (a+0xd3a2646c) ^ (a<<9);
    a = (a+0xfd7046c5) + (a<<3);
    a = (a^0xb55a4f09) ^ (a>>16);
    return a;
}

// Writes a given fragment to a fragment buffer at a given location
__host__ __device__ void writeToDepthbuffer(int x, int y, fragment frag, fragment* depthbuffer, glm::vec2 resolution){
  if(x<resolution.x && y<resolution.y){
    int index = (y*resolution.x) + x;
    depthbuffer[index] = frag;
  }
}

//Reads a fragment from a given location in a fragment buffer
__host__ __device__ fragment getFromDepthbuffer(int x, int y, fragment* depthbuffer, glm::vec2 resolution){
  if(x<resolution.x && y<resolution.y){
    int index = (y*resolution.x) + x;
    return depthbuffer[index];
  }else{
    fragment f;
    return f;
  }
}

//Writes a given pixel to a pixel buffer at a given location
__host__ __device__ void writeToFramebuffer(int x, int y, glm::vec3 value, glm::vec3* framebuffer, glm::vec2 resolution){
  if(x<resolution.x && y<resolution.y){
    int index = (y*resolution.x) + x;
    framebuffer[index] = value;
  }
}

//Reads a pixel from a pixel buffer at a given location
__host__ __device__ glm::vec3 getFromFramebuffer(int x, int y, glm::vec3* framebuffer, glm::vec2 resolution){
  if(x<resolution.x && y<resolution.y){
    int index = (y*resolution.x) + x;
    return framebuffer[index];
  }else{
    return glm::vec3(0,0,0);
  }
}

//Kernel that clears a given pixel buffer with a given color
__global__ void clearImage(glm::vec2 resolution, glm::vec3* image, glm::vec3 color){
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * resolution.x);
    if(x<=resolution.x && y<=resolution.y){
      image[index] = color;
    }
}

//Kernel that clears a given fragment buffer with a given fragment
__global__ void clearDepthBuffer(glm::vec2 resolution, int* lockbuffer, fragment* buffer, fragment frag){
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * resolution.x);
    if(x<=resolution.x && y<=resolution.y){
      fragment f = frag;
      f.position.x = x;
      f.position.y = y;
      buffer[index] = f;
    }
	lockbuffer[index] = 0;
}

//Kernel that writes the image to the OpenGL PBO directly. 
__global__ void sendImageToPBO(uchar4* PBOpos, glm::vec2 resolution, glm::vec3* image){
  
  int x = (blockIdx.x * blockDim.x) + threadIdx.x;
  int y = (blockIdx.y * blockDim.y) + threadIdx.y;
  int index = x + (y * resolution.x);
  
  if(x<=resolution.x && y<=resolution.y){

      glm::vec3 color;      
      color.x = image[index].x*255.0;
      color.y = image[index].y*255.0;
      color.z = image[index].z*255.0;

      if(color.x>255){
        color.x = 255;
      }

      if(color.y>255){
        color.y = 255;
      }

      if(color.z>255){
        color.z = 255;
      }
      
      // Each thread writes one pixel location in the texture (textel)
      PBOpos[index].w = 0;
      PBOpos[index].x = color.x;     
      PBOpos[index].y = color.y;
      PBOpos[index].z = color.z;
  }
}

//TODO: Implement a vertex shader
__global__ void vertexShadeKernel(float* vbo, float* vbo_proj, int vbosize, glm::mat4 modelMatrix, glm::mat4 viewMatrix, 
								  glm::mat4 projectionMatrix, glm::vec2 resolution)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if(index<vbosize/3){

		// window resolution
		float width = resolution.x;
		float height = resolution.y;

		// create original model space vertex vector
		glm::vec4 vO(vbo[index*3 + 0], vbo[index*3 + 1], vbo[index*3 + 2], 1.0);

		// transform with MVP matrix
		glm::vec4 vT = projectionMatrix * viewMatrix * modelMatrix * vO;

		// transform to window space
		glm::vec3 vS = glm::vec3(vT.x/vT.w*(float)width/2 + (float)width/2, vT.y/vT.w*(float)height/2 + (float)height/2, vT.z/vT.w);
	  
		// store transformed vertex position
		vbo_proj[index*3 + 0] = vS.x;
		vbo_proj[index*3 + 1] = vS.y;
		vbo_proj[index*3 + 2] = vS.z;
	}
}

//TODO: Implement primitive assembly
__global__ void primitiveAssemblyKernel(float* vbo, float* vbo_proj, int vbosize, float* cbo, int cbosize, int* ibo, int ibosize, 
										float* nbo, triangle* primitives)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	int primitivesCount = ibosize/3;
	
	if(index<primitivesCount){
		
		// 3 face vertex indices
		int vertID0 = ibo[3*index+0];
		int vertID1 = ibo[3*index+1];
		int vertID2 = ibo[3*index+2];
		
		// back face culling
		glm::vec3 v0(vbo_proj[3*vertID0],vbo_proj[3*vertID0+1],vbo_proj[3*vertID0+2]);
		glm::vec3 v1(vbo_proj[3*vertID1],vbo_proj[3*vertID1+1],vbo_proj[3*vertID1+2]);
		glm::vec3 v2(vbo_proj[3*vertID2],vbo_proj[3*vertID2+1],vbo_proj[3*vertID2+2]);
		int edgeSum = 0;
		edgeSum += (v1.x-v0.x)*(v1.y+v0.y);
		edgeSum += (v2.x-v1.x)*(v2.y+v1.y);
		edgeSum += (v0.x-v2.x)*(v0.y+v2.y);
		if (edgeSum > 0) {
			primitives[index].visible = false;
			return;
		}
		
		// create new triangle
		triangle newTriangle;

		// triangle vertex points
		newTriangle.p0 = v0;
		newTriangle.p1 = v1;
		newTriangle.p2 = v2;

		// triangle vertex positions
		newTriangle.f0.position = glm::vec3(vbo[3*vertID0],vbo[3*vertID0+1],vbo[3*vertID0+2]);
		newTriangle.f1.position = glm::vec3(vbo[3*vertID1],vbo[3*vertID1+1],vbo[3*vertID1+2]);
		newTriangle.f2.position = glm::vec3(vbo[3*vertID2],vbo[3*vertID2+1],vbo[3*vertID2+2]);

		// triangle vertex colors
		newTriangle.f0.color = glm::vec3(cbo[3*(vertID0 % 3)], cbo[3*(vertID0 % 3) + 1], cbo[3*(vertID0 % 3) + 2]);
		newTriangle.f1.color = glm::vec3(cbo[3*(vertID1 % 3)], cbo[3*(vertID1 % 3) + 1], cbo[3*(vertID1 % 3) + 2]);
		newTriangle.f2.color = glm::vec3(cbo[3*(vertID2 % 3)], cbo[3*(vertID2 % 3) + 1], cbo[3*(vertID2 % 3) + 2]);
		
		// triangle vertex positions
		newTriangle.f0.normal = glm::vec3(nbo[3*vertID0],nbo[3*vertID0+1],nbo[3*vertID0+2]);
		newTriangle.f1.normal = glm::vec3(nbo[3*vertID1],nbo[3*vertID1+1],nbo[3*vertID1+2]);
		newTriangle.f2.normal = glm::vec3(nbo[3*vertID2],nbo[3*vertID2+1],nbo[3*vertID2+2]);

		newTriangle.visible = true;

		// assign new triangle to primitives list
		primitives[index] = newTriangle;
  }
}

//TODO: Implement a rasterization method, such as scanline.
__global__ void rasterizationKernel(triangle* primitives, int primitivesCount, fragment* depthbuffer, int* lockbuffer, glm::vec2 resolution){
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if(index<primitivesCount){
		
		// get triangle data
		triangle tri = primitives[index];
		if (!tri.visible) return;
		glm::vec3 v0 = tri.p0;
		glm::vec3 v1 = tri.p1;
		glm::vec3 v2 = tri.p2;
		
		// get x and y resolutions
		int xRes = resolution.x;
		int yRes = resolution.y;

		// create edge block structs
		edgeBlock edge0;
		edge0.primitiveID = index;
		edge0.numScanLines = (int)abs(v0.y-v1.y) + 1;
		if (v0.y >= v1.y) {
			edge0.ys = v0.y;
			edge0.xs = v0.x;
			edge0.zs = v0.z;
			edge0.delta_x = (v1.x-v0.x)/edge0.numScanLines;
			edge0.delta_z = (v1.z-v0.z)/edge0.numScanLines;
		} else {
			edge0.ys = v1.y;
			edge0.xs = v1.x;
			edge0.zs = v1.z;
			edge0.delta_x = (v0.x-v1.x)/edge0.numScanLines;
			edge0.delta_z = (v0.z-v1.z)/edge0.numScanLines;}
		
		edgeBlock edge1;
		edge1.primitiveID = index;
		edge1.numScanLines = (int)abs(v1.y-v2.y) + 1;
		if (v1.y >= v2.y) {
			edge1.ys = v1.y;
			edge1.xs = v1.x;
			edge1.zs = v1.z;
			edge1.delta_x = (v2.x-v1.x)/edge1.numScanLines;
			edge1.delta_z = (v2.z-v1.z)/edge1.numScanLines;
		} else {
			edge1.ys = v2.y;
			edge1.xs = v2.x;
			edge1.zs = v2.z;
			edge1.delta_x = (v1.x-v2.x)/edge1.numScanLines;
			edge1.delta_z = (v1.z-v2.z)/edge1.numScanLines;}
		
		edgeBlock edge2;
		edge2.primitiveID = index;
		edge2.numScanLines = (int)abs(v2.y-v0.y) + 1;
		if (v2.y >= v0.y) {
			edge2.ys = v2.y;
			edge2.xs = v2.x;
			edge2.zs = v2.z;
			edge2.delta_x = (v0.x-v2.x)/edge2.numScanLines;
			edge2.delta_z = (v0.z-v2.z)/edge2.numScanLines;
		} else {
			edge2.ys = v0.y;
			edge2.xs = v0.x;
			edge2.zs = v0.z;
			edge2.delta_x = (v2.x-v0.x)/edge2.numScanLines;
			edge2.delta_z = (v2.z-v0.z)/edge2.numScanLines;}

		// create initial y-sorted list of polygon edges
		int init_idx = 0;
		edgeBlock init[3];
		int ys0 = edge0.ys; int ys1 = edge1.ys; int ys2 = edge2.ys;
		if (ys0 >= ys1 && ys0 >= ys2) {
			init[0] = edge0;
			if (ys1 >= ys2) { init[1] = edge1; init[2] = edge2; }
			else		    { init[1] = edge2; init[2] = edge1; }
		}else if (ys1 >= ys0 && ys1 >= ys2) {
			init[0] = edge1;
			if (ys0 >= ys2) { init[1] = edge0; init[2] = edge2; }
			else		    { init[1] = edge2; init[2] = edge0; }
		}else {
			init[0] = edge2;
			if (ys1 >= ys0) { init[1] = edge1; init[2] = edge0; }
			else		    { init[1] = edge0; init[2] = edge1; }
		}
	
		// initialize empty scan bucket to iterate through image
		int activeEdges = 0;
		edgeBlock scanBucket[3];

		// iterate through image
		for (int s = yRes; s >= 0; s--) {

			// delete newly passed edges
			for (int i = 0; i < activeEdges; i++) {
				if (scanBucket[i].numScanLines <= 0) {
					for (int j = i; j < 2; j++)
						scanBucket[j] = scanBucket[j+1];
					activeEdges--;
					i--;
				}
			}
			
			// add newly intersected edges
			while (init_idx < 3 && init[init_idx].ys >= s)
				scanBucket[activeEdges++] = init[init_idx++];

			// sort active edges based on current x values
			for (int i = activeEdges-1; i > 0; i--) {
				if (scanBucket[i].xs < scanBucket[i-1].xs) {
					edgeBlock temp = scanBucket[i];
					scanBucket[i] = scanBucket[i-1];
					scanBucket[i-1] = temp;
				}
			} if (activeEdges == 3 && scanBucket[2].xs < scanBucket[1].xs) {
				edgeBlock temp = scanBucket[2];
				scanBucket[2] = scanBucket[1];
				scanBucket[1] = temp;
			}
			
			// color fragments
			if (activeEdges >= 2) {
				
				// current scanline segment endpoints in x and z
				float x1, x2, z1, z2;
				x1 = scanBucket[0].xs;
				if (activeEdges == 2) { x2 = scanBucket[1].xs; }
				else				  { x2 = scanBucket[2].xs; }
				z1 = scanBucket[0].zs;
				if (activeEdges == 2) { z2 = scanBucket[1].zs; }
				else				  { z2 = scanBucket[2].zs; }

				for (int x = x1; x <= x2; x++) {

					// compute x,y,z coordinates for pixel
					float z = z1 + (x-x1)/(x2-x1)*(z2-z1);
					
					// pixel buffer index
					int pixelIDX = x + s*xRes;
					
					// assure index is within buffer range
					if (pixelIDX < xRes*yRes) {
						
						// compute barycentric cooordinates
						float area0 = (x*(v1.y-v2.y) + v1.x*(v2.y-s) + v2.x*(s-v1.y)) / 2.0f;
						float area1 = (x*(v2.y-v0.y) + v2.x*(v0.y-s) + v0.x*(s-v2.y)) / 2.0f;
						float area2 = (x*(v0.y-v1.y) + v0.x*(v1.y-s) + v1.x*(s-v0.y)) / 2.0f;
						float triangleArea = (v0.x*(v1.y-v2.y) + v1.x*(v2.y-v0.y) + v2.x*(v0.y-v1.y)) / 2.0f;

						// compute colorfullBlocksPerGrid, threadsPerBlock
						glm::vec3 color0 = glm::vec3(1.0f);//tri.f0.color;
						glm::vec3 color1 = glm::vec3(1.0f);//tri.f1.color;
						glm::vec3 color2 = glm::vec3(1.0f);//tri.f2.color;
						glm::vec3 color = ((area0 * color0) + (area1 * color1) + (area2 * color2)) / triangleArea;

						// compute normal
						glm::vec3 normal0 = tri.f0.normal;
						glm::vec3 normal1 = tri.f1.normal;
						glm::vec3 normal2 = tri.f2.normal;
						glm::vec3 normal = glm::normalize(((area0 *normal0) + (area1 * normal1) + (area2 * normal2)) / triangleArea);

						//compute position
						glm::vec3 position0 = tri.f0.position;
						glm::vec3 position1 = tri.f1.position;
						glm::vec3 position2 = tri.f2.position;
						glm::vec3 position = ((area0 *position0) + (area1 * position1) + (area2 * position2)) / triangleArea;

						//while (atomicMax(&lockbuffer[pixelIDX], 1) == 1);

						/****** BEGIN CRITICAL SECTION ******/	

						//assign color, position, and normal values
						if (depthbuffer[pixelIDX].position.z < z || depthbuffer[pixelIDX].position.z == -10000) {
							depthbuffer[pixelIDX].color = color;
							depthbuffer[pixelIDX].normal = normal;
							depthbuffer[pixelIDX].position = position;
						}

						/****** END CRITICAL SECTION ******/

						//atomicMin(&lockbuffer[pixelIDX], 0);
					}
				}
			}			

			// update numScanLines, xs, and zs
			for (int i = 0; i < activeEdges; i++) {
				scanBucket[i].numScanLines--;
				scanBucket[i].xs += scanBucket[i].delta_x;
				scanBucket[i].zs += scanBucket[i].delta_z;
			}
		}
	}
}

//TODO: Implement a fragment shader
__global__ void fragmentShadeKernel(fragment* depthbuffer, glm::vec2 resolution, glm::vec3 lightPos){
  int x = (blockIdx.x * blockDim.x) + threadIdx.x;
  int y = (blockIdx.y * blockDim.y) + threadIdx.y;
  int index = x + (y * resolution.x);
  if(x<=resolution.x && y<=resolution.y){
	  float ambient = 0.2f;
	  glm::vec3 N = depthbuffer[index].normal;
	  glm::vec3 L = glm::normalize(lightPos - depthbuffer[index].position);
	  depthbuffer[index].color = depthbuffer[index].color * (ambient + (1.0f - ambient)*max(glm::dot(N,L), 0.0f));
  }
}

//Writes fragment colors to the framebuffer
__global__ void render(glm::vec2 resolution, fragment* depthbuffer, glm::vec3* framebuffer){

  int x = (blockIdx.x * blockDim.x) + threadIdx.x;
  int y = (blockIdx.y * blockDim.y) + threadIdx.y;
  int index = x + (y * resolution.x);

  if(x<=resolution.x && y<=resolution.y){
    framebuffer[index] = depthbuffer[index].color;
  }
}

// Wrapper for the __global__ call that sets up the kernel calls and does a ton of memory management
void cudaRasterizeCore(uchar4* PBOpos, glm::vec2 resolution, float frame, float* vbo, int vbosize, float* cbo, int cbosize, int* ibo, int ibosize,
					   float* nbo, int nbosize, glm::mat4 modelMat, glm::mat4 viewMat, glm::mat4 projMat, glm::vec3 lightPos){

  // set up crucial magic
  int tileSize = 8;
  dim3 threadsPerBlock(tileSize, tileSize);
  dim3 fullBlocksPerGrid((int)ceil(float(resolution.x)/float(tileSize)), (int)ceil(float(resolution.y)/float(tileSize)));

  //set up framebuffer
  framebuffer = NULL;
  cudaMalloc((void**)&framebuffer, (int)resolution.x*(int)resolution.y*sizeof(glm::vec3));
  
  //set up depthbuffer
  depthbuffer = NULL;
  cudaMalloc((void**)&depthbuffer, (int)resolution.x*(int)resolution.y*sizeof(fragment));
  
  //set up depthbuffer
  lockbuffer = NULL;
  cudaMalloc((void**)&lockbuffer, (int)resolution.x*(int)resolution.y*sizeof(int));

  //kernel launches to black out accumulated/unaccumlated pixel buffers and clear our scattering states
  clearImage<<<fullBlocksPerGrid, threadsPerBlock>>>(resolution, framebuffer, glm::vec3(0,0,0));
  
  fragment frag;
  frag.color = glm::vec3(0,0,0);
  frag.normal = glm::vec3(0,0,0);
  frag.position = glm::vec3(0,0,-10000);
  clearDepthBuffer<<<fullBlocksPerGrid, threadsPerBlock>>>(resolution, lockbuffer, depthbuffer,frag);

  //------------------------------
  //memory stuff
  //------------------------------
  primitives = NULL;
  cudaMalloc((void**)&primitives, (ibosize/3)*sizeof(triangle));

  device_ibo = NULL;
  cudaMalloc((void**)&device_ibo, ibosize*sizeof(int));
  cudaMemcpy( device_ibo, ibo, ibosize*sizeof(int), cudaMemcpyHostToDevice);

  device_vbo = NULL;
  cudaMalloc((void**)&device_vbo, vbosize*sizeof(float));
  cudaMemcpy( device_vbo, vbo, vbosize*sizeof(float), cudaMemcpyHostToDevice);
  
  device_vbo_proj = NULL;
  cudaMalloc((void**)&device_vbo_proj, vbosize*sizeof(float));
  cudaMemcpy( device_vbo_proj, vbo, vbosize*sizeof(float), cudaMemcpyHostToDevice);

  device_cbo = NULL;
  cudaMalloc((void**)&device_cbo, cbosize*sizeof(float));
  cudaMemcpy( device_cbo, cbo, cbosize*sizeof(float), cudaMemcpyHostToDevice);

  device_nbo = NULL;
  cudaMalloc((void**)&device_nbo, nbosize*sizeof(float));
  cudaMemcpy( device_nbo, nbo, nbosize*sizeof(float), cudaMemcpyHostToDevice);

  tileSize = 32;
  int primitiveBlocks = ceil(((float)vbosize/3)/((float)tileSize));

  //------------------------------
  //vertex shader
  //------------------------------
  
  vertexShadeKernel<<<primitiveBlocks, tileSize>>>(device_vbo, device_vbo_proj, vbosize, modelMat, viewMat, projMat, resolution);
  
  cudaDeviceSynchronize();
  //------------------------------
  //primitive assembly
  //------------------------------
  primitiveBlocks = ceil(((float)ibosize/3)/((float)tileSize));
  primitiveAssemblyKernel<<<primitiveBlocks, tileSize>>>(device_vbo, device_vbo_proj, vbosize, device_cbo, cbosize, device_ibo, 
														 ibosize, device_nbo, primitives);

  cudaDeviceSynchronize();
  //------------------------------
  //rasterization
  //------------------------------
  rasterizationKernel<<<primitiveBlocks, tileSize>>>(primitives, ibosize/3, depthbuffer, lockbuffer, resolution);

  cudaDeviceSynchronize();
  //------------------------------
  //fragment shader
  //------------------------------
  fragmentShadeKernel<<<fullBlocksPerGrid, threadsPerBlock>>>(depthbuffer, resolution, lightPos);

  cudaDeviceSynchronize();
  //------------------------------
  //write fragments to framebuffer
  //------------------------------
  render<<<fullBlocksPerGrid, threadsPerBlock>>>(resolution, depthbuffer, framebuffer);
  sendImageToPBO<<<fullBlocksPerGrid, threadsPerBlock>>>(PBOpos, resolution, framebuffer);

  cudaDeviceSynchronize();

  kernelCleanup();

  checkCUDAError("Kernel failed!");
}

void kernelCleanup(){
  cudaFree( primitives );
  cudaFree( device_vbo );
  cudaFree( device_vbo_proj );
  cudaFree( device_nbo );
  cudaFree( device_cbo );
  cudaFree( device_ibo );
  cudaFree( framebuffer );
  cudaFree( depthbuffer );
  cudaFree( lockbuffer );
}

