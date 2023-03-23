#include "mscclpp.h"

#ifdef MSCCLPP_USE_MPI_FOR_TESTS
#include "mpi.h"
#endif // MSCCLPP_USE_MPI_FOR_TESTS
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string>

#ifdef MSCCLPP_USE_MPI_FOR_TESTS
int RANKS_PER_NODE;
#else
#define RANKS_PER_NODE 8
#endif

// Propagate errors up

#define MSCCLPPCHECK(call) do { \
  mscclppResult_t res = call; \
  if (res != mscclppSuccess && res != mscclppInProgress) { \
     /* Print the back trace*/ \
   printf("Failure at %s:%d -> %d\n", __FILE__, __LINE__, res);    \
       return res; \
  } \
} while (0)


// Check CUDA RT calls
#define CUDACHECK(cmd) do {                                   \
    cudaError_t err = cmd;                                    \
    if( err != cudaSuccess ) {                                \
        printf("%s:%d Cuda failure '%s'\n", __FILE__, __LINE__, cudaGetErrorString(err)); \
        exit(EXIT_FAILURE);                                   \
    }                                                         \
} while(false)

// Measure current time in second.
static double getTime(void)
{
  struct timespec tspec;
  if (clock_gettime(CLOCK_MONOTONIC, &tspec) == -1) {
    printf("clock_gettime failed\n");
    exit(EXIT_FAILURE);
  }
  return (tspec.tv_nsec / 1.0e9) + tspec.tv_sec;
}

__constant__ mscclppDevConn_t constDevConns[16];

__device__ void allgather0(mscclppDevConn_t devConn, int rank, int world_size, int remoteRank, int nelemsPerGPU){
  // this allgather is really simple and implemented as an alltoall

  // this thread's role is a sender role
  // put your data asynchronously
  devConn.put(rank * nelemsPerGPU * sizeof(int), nelemsPerGPU*sizeof(int));
  // push with flag and sync to make sure the data is received
  devConn.signal();
  
  // this thread's role is a receiver role. wait on the semaphore to make sure the data is ready
  devConn.wait();
}

__device__ void allgather1(mscclppDevConn_t devConn, int rank, int world_size, int remoteRank, int nelemsPerGPU){
  // this allgather algorithm works as follows:
  // Step 1: GPU rank i sends data to GPU rank (i+1) % world_size
  // Step 2: GPU rank i waits for data from GPU rank (i+2) % world_size
  // ...
  // This order is much better for DMA engine for NVLinks

  for (int i = 1; i < world_size; i++){
    __syncthreads();
    if (remoteRank != ((rank+i) % world_size)) continue;
    // put your data to GPU (rank+i) % world_size and signal all in one call
    devConn.putWithSignal(rank * nelemsPerGPU * sizeof(int), nelemsPerGPU*sizeof(int));
  }
  // all connections wait for the signal from the sender
  devConn.wait();
}

__global__ void kernel(int rank, int world_size, int nelemsPerGPU, int kernel)
{
  // only use a single thread from each warp
  if (threadIdx.x % 32 != 0) return;

  // find the mapping between remoteRank and devConns
  int warpId = threadIdx.x / 32;
  int remoteRank = (warpId < rank) ? warpId : warpId + 1;
  // Each warp is responsible for one of the remote ranks
  mscclppDevConn_t devConn = constDevConns[warpId];

  if (kernel == 0)
    allgather0(devConn, rank, world_size, remoteRank, nelemsPerGPU);
  else if (kernel == 1)
    allgather1(devConn, rank, world_size, remoteRank, nelemsPerGPU);
}

int rankToLocalRank(int rank)
{
  return rank % RANKS_PER_NODE;
}

int rankToNode(int rank)
{
  return rank / RANKS_PER_NODE;
}

void print_usage(const char *prog)
{
#ifdef MSCCLPP_USE_MPI_FOR_TESTS
  printf("usage: %s IP:PORT [rank nranks]\n", prog);
#else
  printf("usage: %s IP:PORT rank nranks\n", prog);
#endif
}

void initializeAndAllocateAllGatherData(int rank, int world_size, size_t data_size, int nelemsPerGPU, int** data_h, int **data_d)
{
  CUDACHECK(cudaMalloc(data_d, data_size));
  CUDACHECK(cudaMemset(*data_d, 0, data_size));

  *data_h = new int[nelemsPerGPU*world_size];
  for (int i = 0; i < nelemsPerGPU*world_size; i++){
    int val = i + 1;
    if (i / nelemsPerGPU == rank){
      (*data_h)[i] = val;
    } else {
      (*data_h)[i] = 0;
    }
  }
  CUDACHECK(cudaMemcpy(*data_d, *data_h, data_size, cudaMemcpyHostToDevice));
}

mscclppResult_t setupMscclppConnections(int rank, int world_size, mscclppComm_t comm, int* data_d, size_t data_size){
  int thisNode = rankToNode(rank);
  int cudaNum = rankToLocalRank(rank);
  std::string ibDevStr = "mlx5_ib" + std::to_string(cudaNum);

  for (int r = 0; r < world_size; ++r) {
    if (r == rank) continue;
    mscclppTransport_t transportType;
    const char* ibDev = ibDevStr.c_str();
    if (rankToNode(r) == thisNode){
      ibDev = NULL;
      transportType = mscclppTransportP2P;
    } else {
      transportType = mscclppTransportIB;
    }
    // Connect with all other ranks
    MSCCLPPCHECK(mscclppConnect(comm, r, 0, data_d, data_size, transportType, ibDev));
  }

  MSCCLPPCHECK(mscclppConnectionSetup(comm));

  mscclppDevConn_t *devConns;
  int nCons;
  MSCCLPPCHECK(mscclppGetAllDeviceConnections(comm, &devConns, &nCons));

  CUDACHECK(cudaMemcpyToSymbol(constDevConns, devConns, sizeof(mscclppDevConn_t) * nCons));

  return mscclppSuccess;
}

int main(int argc, const char *argv[])
{
#ifdef MSCCLPP_USE_MPI_FOR_TESTS
  if (argc != 2 && argc != 4) {
    print_usage(argv[0]);
    return -1;
  }
  const char *ip_port = argv[1];
  int rank;
  int world_size;
  if (argc == 4) {
    rank = atoi(argv[2]);
    world_size = atoi(argv[3]);
  } else {
    MPI_Init(NULL, NULL);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &world_size);
  }
  // get the local number of nodes with MPI
  MPI_Comm shmcomm;
  MPI_Comm_split_type(MPI_COMM_WORLD, MPI_COMM_TYPE_SHARED, 0,
                      MPI_INFO_NULL, &shmcomm);
  int shmrank;
  MPI_Comm_size(shmcomm, &shmrank);
  RANKS_PER_NODE = shmrank;
  MPI_Comm_free(&shmcomm);
#else
  if (argc != 4) {
    print_usage(argv[0]);
    return -1;
  }
  const char *ip_port = argv[1];
  int rank = atoi(argv[2]);
  int world_size = atoi(argv[3]);
#endif

  int kernelNum = 1;

  int thisNode = rankToNode(rank);
  int cudaNum = rankToLocalRank(rank);
  CUDACHECK(cudaSetDevice(cudaNum));

  mscclppComm_t comm;
  MSCCLPPCHECK(mscclppCommInitRank(&comm, world_size, rank, ip_port));

  int *data_d;
  int *data_h;
  size_t data_size = 1024*1024*1024;
  int nelemsPerGPU = data_size / sizeof(int) / world_size;

  initializeAndAllocateAllGatherData(rank, world_size, data_size, nelemsPerGPU, &data_h, &data_d);

  MSCCLPPCHECK(setupMscclppConnections(rank, world_size, comm, data_d, data_size));

  MSCCLPPCHECK(mscclppProxyLaunch(comm));

  cudaStream_t stream;
  CUDACHECK(cudaStreamCreateWithFlags(&stream, cudaStreamNonBlocking));

  CUDACHECK(cudaDeviceSynchronize());
  kernel<<<1, 32 * (world_size - 1), 0, stream>>>(rank, world_size, nelemsPerGPU, kernelNum);
  CUDACHECK(cudaDeviceSynchronize());
  CUDACHECK(cudaMemcpy(data_h, data_d, data_size, cudaMemcpyDeviceToHost));
  CUDACHECK(cudaDeviceSynchronize());

  for (int i = 0; i < nelemsPerGPU*world_size; i++){
    int val = i + 1;
    if (data_h[i] != val){
      printf("oh uh things went wrong! data_h[%d] (%d) != val (%d)\n", i, data_h[i], val);
      break;
    }
  }
  int tmp[16];
  MSCCLPPCHECK(mscclppBootStrapAllGather(comm, tmp, sizeof(int)));

//   // Perf test
//   cudaEvent_t ev_start;
//   cudaEvent_t ev_end;
//   CUDACHECK(cudaEventCreate(&ev_start));
//   CUDACHECK(cudaEventCreate(&ev_end));

  // warm up
  // int warmupiter = 1000;
  // for (int i = 0; i < warmupiter; ++i) {
  //   kernel<<<1, 32 * (world_size - 1), 0, stream>>>(rank, world_size, nelemsPerGPU, kernelNum);
  // }
  // CUDACHECK(cudaDeviceSynchronize());
  // MSCCLPPCHECK(mscclppBootStrapAllGather(comm, tmp, sizeof(int)));

  // cudaGraph Capture
  cudaGraph_t graph;
  cudaGraphExec_t instance;
  cudaStreamBeginCapture(stream, cudaStreamCaptureModeGlobal);
  int cudagraphiter = 10;
  for (int i = 0; i < cudagraphiter; ++i) {
  	kernel<<<1, 32 * (world_size - 1), 0, stream>>>(rank, world_size, nelemsPerGPU, kernelNum);
  }
  cudaStreamEndCapture(stream, &graph);
  cudaGraphInstantiate(&instance, graph, NULL, NULL, 0);

  int cudagraphwarmup = 10;
  for (int i = 0; i < cudagraphwarmup; ++i) {
	  cudaGraphLaunch(instance, stream);
  }
  CUDACHECK(cudaStreamSynchronize(stream));

  // measure runtime 
//  CUDACHECK(cudaEventRecord(ev_start, stream));
  double t0 = getTime();
  int cudagraphlaunch = 10;
  for (int i = 0; i < cudagraphlaunch; ++i) {
  // kernel<<<1, 32 * (world_size - 1), 0, stream>>>(rank, world_size);
     cudaGraphLaunch(instance, stream);
  }
//  CUDACHECK(cudaEventRecord(ev_end, stream));
  CUDACHECK(cudaStreamSynchronize(stream));

  double t1 = getTime();
  float ms = (t1-t0)*1000.0;
//  CUDACHECK(cudaEventElapsedTime(&ms, ev_start, ev_end));
  double time_in_us = ms * 1000. / (float) cudagraphlaunch / (float) cudagraphiter;
  printf("rank: %d, time: %f us/iter algBW %f GBps\n", rank, time_in_us, (double) (data_size) / 1e9 /(time_in_us/1e6));

  MSCCLPPCHECK(mscclppBootStrapAllGather(comm, tmp, sizeof(int)));
  MSCCLPPCHECK(mscclppProxyStop(comm));

  MSCCLPPCHECK(mscclppCommDestroy(comm));

#ifdef MSCCLPP_USE_MPI_FOR_TESTS
  if (argc == 2) {
    MPI_Finalize();
  }
#endif
  printf("Succeeded! %d\n", rank);
  return 0;
}
