#include "communicator.hpp"

#include <mscclpp/core.hpp>
#include <sstream>

#include "api.h"
#include "checks_internal.hpp"
#include "connection.hpp"
#include "debug.h"
#include "registered_memory.hpp"
#include "utils.h"

namespace mscclpp {

Communicator::Impl::Impl(std::shared_ptr<BaseBootstrap> bootstrap) : bootstrap_(bootstrap) {
  rankToHash_.resize(bootstrap->getNranks());
  auto hostHash = getHostHash();
  INFO(MSCCLPP_INIT, "Host hash: %lx", hostHash);
  rankToHash_[bootstrap->getRank()] = hostHash;
  bootstrap->allGather(rankToHash_.data(), sizeof(uint64_t));

  MSCCLPP_CUDATHROW(cudaStreamCreateWithFlags(&ipcStream_, cudaStreamNonBlocking));
}

Communicator::Impl::~Impl() {
  ibContexts_.clear();

  cudaStreamDestroy(ipcStream_);
}

IbCtx* Communicator::Impl::getIbContext(Transport ibTransport) {
  // Find IB context or create it
  auto it = ibContexts_.find(ibTransport);
  if (it == ibContexts_.end()) {
    auto ibDev = getIBDeviceName(ibTransport);
    ibContexts_[ibTransport] = std::make_unique<IbCtx>(ibDev);
    return ibContexts_[ibTransport].get();
  } else {
    return it->second.get();
  }
}

cudaStream_t Communicator::Impl::getIpcStream() { return ipcStream_; }

MSCCLPP_API_CPP Communicator::~Communicator() = default;

MSCCLPP_API_CPP Communicator::Communicator(std::shared_ptr<BaseBootstrap> bootstrap)
    : pimpl(std::make_unique<Impl>(bootstrap)) {}

MSCCLPP_API_CPP std::shared_ptr<BaseBootstrap> Communicator::bootstrapper() { return pimpl->bootstrap_; }

MSCCLPP_API_CPP RegisteredMemory Communicator::registerMemory(void* ptr, size_t size, TransportFlags transports) {
  return RegisteredMemory(
      std::make_shared<RegisteredMemory::Impl>(ptr, size, pimpl->bootstrap_->getRank(), transports, *pimpl));
}

struct MemorySender : public Setuppable {
  MemorySender(RegisteredMemory memory, int remoteRank, int tag)
      : memory_(memory), remoteRank_(remoteRank), tag_(tag) {}

  void beginSetup(std::shared_ptr<BaseBootstrap> bootstrap) override {
    bootstrap->send(memory_.serialize(), remoteRank_, tag_);
  }

  RegisteredMemory memory_;
  int remoteRank_;
  int tag_;
};

MSCCLPP_API_CPP void Communicator::sendMemoryOnSetup(RegisteredMemory memory, int remoteRank, int tag) {
  onSetup(std::make_shared<MemorySender>(memory, remoteRank, tag));
}

struct MemoryReceiver : public Setuppable {
  MemoryReceiver(int remoteRank, int tag) : remoteRank_(remoteRank), tag_(tag) {}

  void endSetup(std::shared_ptr<BaseBootstrap> bootstrap) override {
    std::vector<char> data;
    bootstrap->recv(data, remoteRank_, tag_);
    memoryPromise_.set_value(RegisteredMemory::deserialize(data));
  }

  std::promise<RegisteredMemory> memoryPromise_;
  int remoteRank_;
  int tag_;
};

MSCCLPP_API_CPP NonblockingFuture<RegisteredMemory> Communicator::recvMemoryOnSetup(int remoteRank, int tag) {
  auto memoryReceiver = std::make_shared<MemoryReceiver>(remoteRank, tag);
  onSetup(memoryReceiver);
  return NonblockingFuture<RegisteredMemory>(memoryReceiver->memoryPromise_.get_future());
}

MSCCLPP_API_CPP std::shared_ptr<Connection> Communicator::connectOnSetup(int remoteRank, int tag, Transport transport) {
  std::shared_ptr<ConnectionBase> conn;
  if (transport == Transport::CudaIpc) {
    // sanity check: make sure the IPC connection is being made within a node
    if (pimpl->rankToHash_[remoteRank] != pimpl->rankToHash_[pimpl->bootstrap_->getRank()]) {
      std::stringstream ss;
      ss << "Cuda IPC connection can only be made within a node: " << remoteRank << "(" << std::hex
         << pimpl->rankToHash_[pimpl->bootstrap_->getRank()] << ")"
         << " != " << pimpl->bootstrap_->getRank() << "(" << std::hex
         << pimpl->rankToHash_[pimpl->bootstrap_->getRank()] << ")";
      throw mscclpp::Error(ss.str(), ErrorCode::InvalidUsage);
    }
    auto cudaIpcConn = std::make_shared<CudaIpcConnection>(remoteRank, tag, pimpl->getIpcStream());
    conn = cudaIpcConn;
    INFO(MSCCLPP_P2P, "Cuda IPC connection between rank %d(%lx) and remoteRank %d(%lx) created",
         pimpl->bootstrap_->getRank(), pimpl->rankToHash_[pimpl->bootstrap_->getRank()], remoteRank,
         pimpl->rankToHash_[remoteRank]);
  } else if (AllIBTransports.has(transport)) {
    auto ibConn = std::make_shared<IBConnection>(remoteRank, tag, transport, *pimpl);
    conn = ibConn;
    INFO(MSCCLPP_NET, "IB connection between rank %d(%lx) via %s and remoteRank %d(%lx) created",
         pimpl->bootstrap_->getRank(), pimpl->rankToHash_[pimpl->bootstrap_->getRank()],
         getIBDeviceName(transport).c_str(), remoteRank, pimpl->rankToHash_[remoteRank]);
  } else {
    throw mscclpp::Error("Unsupported transport", ErrorCode::InternalError);
  }
  pimpl->connections_.push_back(conn);
  onSetup(conn);
  return conn;
}

MSCCLPP_API_CPP void Communicator::onSetup(std::shared_ptr<Setuppable> setuppable) {
  pimpl->toSetup_.push_back(setuppable);
}

MSCCLPP_API_CPP void Communicator::setup() {
  for (auto& setuppable : pimpl->toSetup_) {
    setuppable->beginSetup(pimpl->bootstrap_);
  }
  for (auto& setuppable : pimpl->toSetup_) {
    setuppable->endSetup(pimpl->bootstrap_);
  }
  pimpl->toSetup_.clear();
}

}  // namespace mscclpp