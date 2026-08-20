#include <gtest/gtest.h>

#include "grpc_service.hpp"

TEST(ExampleServiceTest, PingEchoesMessage) {
  ExampleServiceImpl service;
  grpc::ServerContext context;
  app_template::PingRequest request;
  request.set_message("hello");
  app_template::PingResponse response;

  grpc::Status status = service.Ping(&context, &request, &response);

  EXPECT_TRUE(status.ok());
  EXPECT_EQ(response.message(), "pong: hello");
}
